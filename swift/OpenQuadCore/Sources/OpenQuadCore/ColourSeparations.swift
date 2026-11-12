// Colour separations: a colour photo split into negatives by colour, one per coat of a
// coloured pigment (tricolour gum, cyanotype under gum, ...). Mirrors
// openquad/colour_separations.py.
//
// Each coat is described by the colour it prints at full strength on white paper. Coats stack
// like filters: their optical densities add, so coats printed at strengths s_k (0 nothing to 1
// full) give, in each of red, green and blue, the density sum_k s_k * D_k, where D_k is
// -log10 of coat k's colour in linear light. For each colour of the photo the strengths are
// the ones whose stack comes closest to it in density, each kept within 0-1 (a bounded least
// squares, with a slight pull toward weaker coats so the split is unique).
//
// The saturation setting scales the photo's chroma (in OKLab) before the split: above 1 the
// coats separate more strongly, for processes (cyanotype, gum) whose prints come out duller
// than the photo. The split is worked out once on a 33 x 33 x 33 grid of sRGB colours and
// interpolated trilinearly for every pixel; the photo's colour is read as sRGB.

import Foundation

public struct ColourSeparation: Sendable, Equatable {
    public static let minCoats = 2, maxCoats = 4
    public static let maxSaturation = 2.0
    /// sRGB levels per channel the split is worked out at.
    public static let grid = 33
    /// Linear light: the deepest the photo is taken to go (density 3).
    static let darkest = 1e-3
    /// The least density a coat needs in some channel to be printed at all.
    static let palest = 0.02
    /// How strongly the split favours weaker coats.
    static let pull = 0.01
    /// How far past 0-1 a solved strength may land and still be taken (then clipped).
    static let slack = 1e-9

    /// Pigments to start from: the colour each prints at full strength on white paper, sRGB.
    public static let pigments: [(name: String, colour: RGB8)] = [
        ("Cyanotype blue", RGB8(34, 74, 140)),
        ("Hansa yellow", RGB8(242, 194, 48)),
        ("Quinacridone magenta", RGB8(176, 48, 106)),
        ("Phthalo blue", RGB8(31, 95, 168)),
        ("Phthalo green", RGB8(29, 107, 87)),
        ("Burnt sienna", RGB8(154, 74, 38)),
        ("Van Dyke brown", RGB8(90, 58, 34)),
        ("Lamp black", RGB8(42, 42, 42)),
    ]
    public static let defaultCoats = ["Cyanotype blue", "Quinacridone magenta", "Hansa yellow"]

    public static func pigment(_ name: String) -> RGB8? { pigments.first { $0.name == name }?.colour }

    /// An 8-bit sRGB colour.
    public struct RGB8: Sendable, Hashable {
        public let r: Int, g: Int, b: Int
        public init(_ r: Int, _ g: Int, _ b: Int) { (self.r, self.g, self.b) = (r, g, b) }

        /// e.g. "#B0306A".
        public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

        /// "#B0306A" (or without the #).
        public init(hex text: String) throws {
            var digits = text.trimmingCharacters(in: .whitespaces)
            if digits.hasPrefix("#") { digits.removeFirst() }
            guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = Int(digits, radix: 16) else {
                throw BuildError(description: "not a colour like #B0306A: \(pyRepr(text))")
            }
            self.init(value >> 16, (value >> 8) & 255, value & 255)
        }
    }

    /// The coats, in the order they are printed, each the colour it prints at full strength.
    public let coats: [RGB8]
    /// How much the photo's chroma is scaled before the split (0-2).
    public let saturation: Double
    /// Each coat's strength at every colour of the grid (red slowest, then green, blue, coat).
    private(set) var lut: [Double]

    public init(coats: [RGB8], saturation: Double = 1) throws {
        try Self.validate(coats: coats, saturation: saturation)
        (self.coats, self.saturation, lut) = (coats, saturation, [])
        lut = strengthLUT(grid: Self.grid)
    }

    /// Throws unless the coats and saturation make a colour separation (without working it out).
    public static func validate(coats: [RGB8], saturation: Double) throws {
        guard (Self.minCoats...Self.maxCoats).contains(coats.count) else {
            throw BuildError(description: "\(Self.minCoats)-\(Self.maxCoats) coats, got \(coats.count)")
        }
        for (k, coat) in coats.enumerated() {
            guard [coat.r, coat.g, coat.b].allSatisfy({ (0...255).contains($0) }) else {
                throw BuildError(description: "coat \(k + 1)'s colour must be three values 0-255")
            }
            guard Self.density(coat).max()! >= Self.palest else {
                throw BuildError(description: "coat \(k + 1) is too pale to print: pick a stronger colour")
            }
        }
        guard saturation >= 0 && saturation <= Self.maxSaturation else {
            throw BuildError(description: "saturation must be 0-2, got \(SeparationPlan.g(saturation))")
        }
    }

    public static func makeDefault() -> ColourSeparation {
        try! ColourSeparation(coats: defaultCoats.map { pigment($0)! })
    }

    public static func == (a: Self, b: Self) -> Bool { a.coats == b.coats && a.saturation == b.saturation }

    public var count: Int { coats.count }

    /// e.g. "3 coats (#224A8C, #B0306A, #F2C230), saturation 1.5".
    public func describe() -> String {
        "\(count) coats (\(coats.map(\.hex).joined(separator: ", "))), saturation \(SeparationPlan.g(saturation))"
    }

    /// A coat's density in red, green and blue at full strength.
    public static func density(_ colour: RGB8) -> [Double] {
        [colour.r, colour.g, colour.b].map { -log10(max(Colour.srgbToLinear(Double($0) / 255.0), darkest)) }
    }

    // MARK: OKLab, for the saturation

    /// Linear sRGB with its OKLab chroma scaled by `saturation`.
    static func saturate(_ r: Double, _ g: Double, _ b: Double, _ saturation: Double) -> (Double, Double, Double) {
        var lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        var mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        var sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        let a = (1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc) * saturation
        let bb = (0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc) * saturation
        lc = lightness + 0.3963377774 * a + 0.2158037573 * bb
        mc = lightness - 0.1055613458 * a - 0.0638541728 * bb
        sc = lightness - 0.0894841775 * a - 1.2914855480 * bb
        (lc, mc, sc) = (lc * lc * lc, mc * mc * mc, sc * sc * sc)
        return (4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
                -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
                -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
    }

    // MARK: the split

    /// Gauss-Jordan inverse of a small symmetric positive definite matrix (no pivoting).
    static func inverse(_ m: [[Double]]) -> [[Double]] {
        let n = m.count
        var a = m.enumerated().map { i, row in row + (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for i in 0..<n {
            let pivot = a[i][i]
            a[i] = a[i].map { $0 / pivot }
            for r in 0..<n where r != i {
                let factor = a[r][i]
                a[r] = zip(a[r], a[i]).map { $0 - factor * $1 }
            }
        }
        return a.map { Array($0[n...]) }
    }

    struct Pattern {
        let fixed: [Double]
        let free: [Int]
        let p: [[Double]]
        let q: [Double]
    }

    /// For each way the coats can sit (each free, at 0 or at full strength; the last coat
    /// changing fastest): the strengths, the free coats, and the free coats' strengths as
    /// P d + q for a target density d.
    static func patterns(_ density: [[Double]]) -> [Pattern] {
        let n = density.count
        let gram = (0..<n).map { j in
            (0..<n).map { k in
                (0..<3).reduce(0.0) { $0 + density[j][$1] * density[k][$1] } + (j == k ? pull : 0.0)
            }
        }
        var result: [Pattern] = []
        let total = (0..<n).reduce(1) { acc, _ in acc * 3 }
        for index in 0..<total {
            var states = [Int](repeating: 0, count: n), rest = index
            for k in stride(from: n - 1, through: 0, by: -1) { (states[k], rest) = (rest % 3, rest / 3) }
            let free = (0..<n).filter { states[$0] == 0 }
            let fixed = states.map { $0 == 2 ? 1.0 : 0.0 }
            var p: [[Double]] = [], q: [Double] = []
            if !free.isEmpty {
                let inv = inverse(free.map { j in free.map { gram[j][$0] } })
                let full = (0..<n).filter { states[$0] == 2 }
                let pushed = free.map { j in full.reduce(0.0) { $0 + gram[j][$1] } }
                for row in inv {
                    p.append((0..<3).map { c in free.indices.reduce(0.0) { $0 + row[$1] * density[free[$1]][c] } })
                    q.append(-free.indices.reduce(0.0) { $0 + row[$1] * pushed[$1] })
                }
            }
            result.append(Pattern(fixed: fixed, free: free, p: p, q: q))
        }
        return result
    }

    /// Each coat's strength, 0-1, for an sRGB-encoded colour (0-1).
    public func solve(_ red: Double, _ green: Double, _ blue: Double) -> [Double] {
        solve(red, green, blue, density: coats.map(Self.density), patterns: Self.patterns(coats.map(Self.density)))
    }

    func solve(_ red: Double, _ green: Double, _ blue: Double, density: [[Double]], patterns: [Pattern]) -> [Double] {
        var (r, g, b) = (Colour.srgbToLinear(red), Colour.srgbToLinear(green), Colour.srgbToLinear(blue))
        if saturation != 1 { (r, g, b) = Self.saturate(r, g, b, saturation) }
        let d = [r, g, b].map { -log10(clip($0, Self.darkest, 1.0)) }
        let n = count
        var best = Double.infinity
        var strengths = [Double](repeating: 0, count: n)
        var s = strengths
        for pattern in patterns {
            s = pattern.fixed
            var feasible = true
            for (i, k) in pattern.free.enumerated() {
                let row = pattern.p[i]
                let value = row[0] * d[0] + row[1] * d[1] + row[2] * d[2] + pattern.q[i]
                if !(value >= -Self.slack && value <= 1.0 + Self.slack) { feasible = false }
                s[k] = clip(value, 0.0, 1.0)
            }
            guard feasible else { continue }
            var cost = 0.0
            for c in 0..<3 {
                var residual = s[0] * density[0][c]
                for k in 1..<n { residual = residual + s[k] * density[k][c] }
                residual = residual - d[c]
                cost = cost + residual * residual
            }
            for k in 0..<n { cost = cost + Self.pull * (s[k] * s[k]) }
            if cost < best { (best, strengths) = (cost, s) }
        }
        return strengths
    }

    /// Each coat's strength at every colour of a grid x grid x grid sRGB lattice (red slowest,
    /// then green, blue, and the coats).
    public func strengthLUT(grid: Int) -> [Double] {
        let density = coats.map(Self.density), patterns = Self.patterns(density)
        let levels = (0..<grid).map { Double($0) / Double(grid - 1) }
        var lut = [Double]()
        lut.reserveCapacity(grid * grid * grid * count)
        for r in levels {
            for g in levels {
                for b in levels { lut += solve(r, g, b, density: density, patterns: patterns) }
            }
        }
        return lut
    }

    /// Trilinear lookup of every coat's strength at a 16-bit colour, into `out`.
    func strengths(_ red: UInt16, _ green: UInt16, _ blue: UInt16, into out: inout [Double]) {
        let grid = Self.grid, n = count
        func axis(_ v: UInt16) -> (Int, Double) {
            let x = Double(v) / Double(maxValue) * Double(grid - 1)
            let low = min(Int(x.rounded(.down)), grid - 2)
            return (low, x - Double(low))
        }
        let (i, tr) = axis(red), (j, tg) = axis(green), (k, tb) = axis(blue)
        for coat in 0..<n {
            func at(_ a: Int, _ b: Int, _ c: Int) -> Double { lut[((a * grid + b) * grid + c) * n + coat] }
            func edge(_ a: Int, _ b: Int) -> Double { at(a, b, k) * (1.0 - tb) + at(a, b, k + 1) * tb }
            let near = edge(i, j) * (1.0 - tg) + edge(i, j + 1) * tg
            let far = edge(i + 1, j) * (1.0 - tg) + edge(i + 1, j + 1) * tg
            out[coat] = near * (1.0 - tr) + far * tr
        }
    }

    /// The greyscale image coat `coat`'s negative is made from (its strength as darkness),
    /// from 16-bit colour (row-major RGB) or greyscale (read as neutral) pixels.
    public func coatImage(_ pixels: [UInt16], colour: Bool, coat: Int) -> [UInt16] {
        precondition((0..<count).contains(coat), "coat \(coat + 1) of \(count) doesn't exist")
        let size = colour ? pixels.count / 3 : pixels.count
        var out = [UInt16](repeating: 0, count: size)
        var strength = [Double](repeating: 0, count: count)
        pixels.withUnsafeBufferPointer { px in
            for i in 0..<size {
                if colour { strengths(px[3 * i], px[3 * i + 1], px[3 * i + 2], into: &strength) }
                else { strengths(px[i], px[i], px[i], into: &strength) }
                out[i] = UInt16(rint((1.0 - strength[coat]) * Double(maxValue)))
            }
        }
        return out
    }

    /// What the stacked coats print, as 16-bit sRGB (row-major RGB): each pixel's coat
    /// strengths with their densities added up, before any process curve.
    public func proof(_ pixels: [UInt16], colour: Bool) -> [UInt16] {
        let size = colour ? pixels.count / 3 : pixels.count
        let density = coats.map(Self.density)
        var out = [UInt16](repeating: 0, count: size * 3)
        var s = [Double](repeating: 0, count: count)
        for i in 0..<size {
            if colour { strengths(pixels[3 * i], pixels[3 * i + 1], pixels[3 * i + 2], into: &s) }
            else { strengths(pixels[i], pixels[i], pixels[i], into: &s) }
            for c in 0..<3 {
                var total = s[0] * density[0][c]
                for k in 1..<count { total = total + s[k] * density[k][c] }
                out[3 * i + c] = UInt16(rint(Colour.linearToSRGB(pow(10.0, -total)) * Double(maxValue)))
            }
        }
        return out
    }
}
