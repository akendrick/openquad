// Small numeric helpers that reproduce numpy's behaviour exactly, so the Swift core
// gives bit-for-bit the same results as the Python reference.

/// The largest 16-bit value: full ink in a curve, white in an image.
public let maxValue = 65535

/// numpy.rint: round half to even (Swift's default `.rounded()` rounds half away from zero).
@inlinable
public func rint(_ value: Double) -> Double {
    value.rounded(.toNearestOrEven)
}

/// numpy.clip for one value.
@inlinable
public func clip(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(max(value, low), high)
}

/// numpy.interp for ascending `xp`: linear interpolation, clamped at both ends.
/// Uses numpy's formula (slope * (x - xp[j]) + fp[j]) so results match to the bit.
public func interp(_ x: Double, _ xp: [Double], _ fp: [Double]) -> Double {
    precondition(xp.count == fp.count && !xp.isEmpty, "interp needs matching, non-empty arrays")
    if x <= xp[0] { return fp[0] }
    let last = xp.count - 1
    if x >= xp[last] { return fp[last] }
    // Binary search for j with xp[j] <= x < xp[j + 1].
    var low = 0, high = last
    while high - low > 1 {
        let mid = (low + high) / 2
        if xp[mid] <= x { low = mid } else { high = mid }
    }
    let slope = (fp[low + 1] - fp[low]) / (xp[low + 1] - xp[low])
    return slope * (x - xp[low]) + fp[low]
}

/// numpy.linspace(start, stop, count): start + i * step, with the last value exactly `stop`.
public func linspace(_ start: Double, _ stop: Double, _ count: Int) -> [Double] {
    precondition(count >= 2, "linspace needs at least 2 points")
    let step = (stop - start) / Double(count - 1)
    var values = (0..<count).map { Double($0) * step + start }
    values[count - 1] = stop
    return values
}
