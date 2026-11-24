// numpy's default random generator (numpy.random.default_rng: SeedSequence feeding
// PCG64), reproduced exactly, so targets shuffled "always the same way" in Python are
// shuffled the same way here: permutation() and uniform() give numpy's numbers.

import Foundation

/// numpy.random.SeedSequence for one non-negative integer seed (below 2^32), no spawn key.
struct SeedSequence {
    static let initA: UInt32 = 0x43b0_d7e5, multA: UInt32 = 0x931e_8875
    static let initB: UInt32 = 0x8b51_f9dd, multB: UInt32 = 0x58f3_8ded
    static let mixL: UInt32 = 0xca01_f9dd, mixR: UInt32 = 0x4973_f715
    static let poolSize = 4

    private(set) var pool = [UInt32](repeating: 0, count: poolSize)

    init(_ seed: UInt32) {
        var hashConst = Self.initA
        func hashmix(_ value: UInt32) -> UInt32 {
            var value = value ^ hashConst
            hashConst = hashConst &* Self.multA
            value = value &* hashConst
            return value ^ (value >> 16)
        }
        func mix(_ x: UInt32, _ y: UInt32) -> UInt32 {
            let result = Self.mixL &* x &- Self.mixR &* y
            return result ^ (result >> 16)
        }
        let entropy = [seed]
        for i in 0..<Self.poolSize {
            pool[i] = hashmix(i < entropy.count ? entropy[i] : 0)
        }
        for src in 0..<Self.poolSize {
            for dst in 0..<Self.poolSize where src != dst {
                pool[dst] = mix(pool[dst], hashmix(pool[src]))
            }
        }
    }

    /// generate_state(words, uint64): pairs of 32-bit words, low word first.
    func state64(_ words: Int) -> [UInt64] {
        var hashConst = Self.initB
        var out: [UInt32] = []
        for i in 0..<(2 * words) {
            var value = pool[i % Self.poolSize] ^ hashConst
            hashConst = hashConst &* Self.multB
            value = value &* hashConst
            out.append(value ^ (value >> 16))
        }
        return (0..<words).map { UInt64(out[2 * $0]) | UInt64(out[2 * $0 + 1]) << 32 }
    }
}

/// A 128-bit unsigned integer, as two halves (just what PCG64 needs).
struct UInt128Pair: Equatable {
    var high: UInt64, low: UInt64

    static func &+ (a: Self, b: Self) -> Self {
        let (low, carry) = a.low.addingReportingOverflow(b.low)
        return Self(high: a.high &+ b.high &+ (carry ? 1 : 0), low: low)
    }

    static func &* (a: Self, b: Self) -> Self {
        let (carry, low) = a.low.multipliedFullWidth(by: b.low)
        return Self(high: carry &+ a.high &* b.low &+ a.low &* b.high, low: low)
    }
}

/// numpy.random.Generator(PCG64(seed)): the default_rng(seed) numbers.
public struct NumpyRandom {
    static let multiplier = UInt128Pair(high: 2_549_297_995_355_413_924, low: 4_865_540_595_714_422_341)

    var state: UInt128Pair
    let increment: UInt128Pair
    var buffered: UInt32?

    public init(seed: UInt32) {
        let words = SeedSequence(seed).state64(4)
        let initState = UInt128Pair(high: words[0], low: words[1])
        let initSeq = UInt128Pair(high: words[2], low: words[3])
        increment = UInt128Pair(high: initSeq.high << 1 | initSeq.low >> 63, low: initSeq.low << 1 | 1)
        state = UInt128Pair(high: 0, low: 0)
        step()
        state = state &+ initState
        step()
    }

    mutating func step() { state = state &* Self.multiplier &+ increment }

    /// The next 64 random bits (PCG XSL-RR).
    public mutating func next64() -> UInt64 {
        step()
        let rotation = state.high >> 58
        let value = state.high ^ state.low
        return value >> rotation | value << ((64 - rotation) & 63)
    }

    /// The next 32 bits: each 64 are used as two, low half first.
    public mutating func next32() -> UInt32 {
        if let half = buffered {
            buffered = nil
            return half
        }
        let value = next64()
        buffered = UInt32(truncatingIfNeeded: value >> 32)
        return UInt32(truncatingIfNeeded: value)
    }

    /// A double in [0, 1).
    public mutating func nextDouble() -> Double { Double(next64() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

    /// numpy's random_interval: a whole number from 0 to `max`, by masking and rejecting.
    mutating func interval(_ max: Int) -> Int {
        guard max > 0 else { return 0 }
        var mask = UInt64(max)
        for shift in [1, 2, 4, 8, 16, 32] { mask |= mask >> UInt64(shift) }
        if max <= Int(UInt32.max) {
            while true {
                let value = UInt64(next32()) & mask
                if value <= UInt64(max) { return Int(value) }
            }
        }
        while true {
            let value = next64() & mask
            if value <= UInt64(max) { return Int(value) }
        }
    }

    /// Generator.permutation(count).
    public mutating func permutation(_ count: Int) -> [Int] {
        var values = Array(0..<count)
        var i = count - 1
        while i >= 1 {
            values.swapAt(i, interval(i))
            i -= 1
        }
        return values
    }

    /// Generator.uniform(low, high, count), row-major.
    public mutating func uniform(_ low: Double, _ high: Double, count: Int) -> [Double] {
        (0..<count).map { _ in low + (high - low) * nextDouble() }
    }
}
