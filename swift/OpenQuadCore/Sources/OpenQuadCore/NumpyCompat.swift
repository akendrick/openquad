// More numpy and Pillow behaviour reproduced exactly, for reading prints: pairwise
// summation, linear percentiles, Python rounding and Pillow's bilinear rotate.

import Foundation

/// Python round(x): to the nearest integer, ties to even.
@inlinable
func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

/// Python round(x, digits): correctly rounded to that many decimals.
func pyRound(_ x: Double, _ digits: Int) -> Double {
    Double(String(format: "%.\(digits)f", x))!
}

/// Python's float modulo (the result takes the sign of the divisor).
func pyMod(_ x: Double, _ y: Double) -> Double {
    var mod = fmod(x, y)
    if mod != 0 {
        if (y < 0) != (mod < 0) { mod += y }
    } else {
        mod = copysign(0, y)
    }
    return mod
}

/// numpy's pairwise summation (blocks of 128, eight accumulators), as add.reduce does
/// along a contiguous axis.
func pairwiseSum<T: BinaryFloatingPoint>(_ a: UnsafeBufferPointer<T>) -> T {
    let n = a.count
    if n < 8 {
        var res: T = 0
        for v in a { res += v }
        return res
    }
    if n <= 128 {
        var r = (0..<8).map { a[$0] }
        var i = 8
        while i < n - n % 8 {
            for j in 0..<8 { r[j] += a[i + j] }
            i += 8
        }
        var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
        while i < n {
            res += a[i]
            i += 1
        }
        return res
    }
    var n2 = n / 2
    n2 -= n2 % 8
    return pairwiseSum(UnsafeBufferPointer(rebasing: a[0..<n2])) + pairwiseSum(UnsafeBufferPointer(rebasing: a[n2...]))
}

func pairwiseSum<T: BinaryFloatingPoint>(_ a: [T]) -> T {
    a.withUnsafeBufferPointer { pairwiseSum($0) }
}

/// numpy mean of a 1-D float64 array.
func npMean(_ a: [Double]) -> Double { pairwiseSum(a) / Double(a.count) }

/// numpy var of a 1-D float32 array (the mean and the result are divided in float64,
/// then stored as float32, as numpy does with its integer count).
func npVar(_ a: [Float]) -> Float {
    let mean = Float(Double(pairwiseSum(a)) / Double(a.count))
    let squares = a.map { v -> Float in
        let d = v - mean
        return d * d
    }
    return Float(Double(pairwiseSum(squares)) / Double(a.count))
}

/// numpy percentile (method "linear") of unsorted values, for several q at once.
func percentile(_ values: [Double], _ qs: [Double]) -> [Double] {
    let sorted = values.sorted()
    let n = sorted.count
    return qs.map { q in
        let virtual = Double(n - 1) * (q / 100)
        let previous = Int(virtual.rounded(.down))
        let next = min(previous + 1, n - 1)
        let gamma = virtual - Double(previous)
        let a = sorted[max(min(previous, n - 1), 0)], b = sorted[next]
        let diff = b - a
        return gamma >= 0.5 ? b - diff * (1 - gamma) : a + diff * gamma
    }
}

/// Python slicing bounds [start:end] for a length (negative values count from the end).
@inlinable
func pySlice(_ start: Int, _ end: Int, _ count: Int) -> Range<Int> {
    let s = start < 0 ? max(start + count, 0) : min(start, count)
    let e = end < 0 ? max(end + count, 0) : min(end, count)
    return s..<max(s, e)
}

/// A float32 image ("F" mode in Pillow), row-major.
struct FloatImage {
    var width: Int
    var height: Int
    var pixels: [Float]
}

/// Pillow's Image.rotate(angle, BILINEAR, center=centre, fillcolor=fill) on an "F"
/// image, without expanding. `region` limits the work to the output rows and columns
/// wanted (the rest stays at the fill).
func pilRotate(_ image: FloatImage, angle: Double, centre: (Double, Double)? = nil, fill: Double,
               region: (rows: Range<Int>, columns: Range<Int>)? = nil) -> FloatImage {
    let w = image.width, h = image.height
    let turn = pyMod(angle, 360.0)
    if centre == nil {
        if turn == 0 { return image }
        if turn == 180 { return FloatImage(width: w, height: h, pixels: image.pixels.reversed()) }
    }
    let (cx, cy) = centre ?? (Double(w) / 2, Double(h) / 2)
    let radians = -(turn * (Double.pi / 180.0))
    let a = pyRound(cos(radians), 15), b = pyRound(sin(radians), 15)
    let d = pyRound(-sin(radians), 15), e = pyRound(cos(radians), 15)
    let c = a * -cx + b * -cy + 0.0 + cx
    let f = d * -cx + e * -cy + 0.0 + cy
    var out = [Float](repeating: Float(fill), count: w * h)
    let rows = region?.rows ?? 0..<h, columns = region?.columns ?? 0..<w
    image.pixels.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            for y in rows {
                let yin = Double(y) + 0.5
                for x in columns {
                    let xin = Double(x) + 0.5
                    var sx = a * xin + b * yin + c
                    var sy = d * xin + e * yin + f
                    if sx < 0.0 || sx >= Double(w) || sy < 0.0 || sy >= Double(h) { continue }
                    sx -= 0.5
                    sy -= 0.5
                    let ix = sx < 0.0 ? Int(floor(sx)) : Int(sx), iy = sy < 0.0 ? Int(floor(sy)) : Int(sy)
                    let dx = sx - Double(ix), dy = sy - Double(iy)
                    let x0 = min(max(ix, 0), w - 1), x1 = min(max(ix + 1, 0), w - 1)
                    let row = min(max(iy, 0), h - 1) * w
                    // In C both neighbours are FLOAT32, so their difference is taken in float32.
                    var v1 = Double(src[row + x0]) + Double(src[row + x1] - src[row + x0]) * dx
                    let v2: Double
                    if iy + 1 >= 0 && iy + 1 < h {
                        let next = (iy + 1) * w
                        v2 = Double(src[next + x0]) + Double(src[next + x1] - src[next + x0]) * dx
                    } else {
                        v2 = v1
                    }
                    v1 = v1 + (v2 - v1) * dy
                    dst[y * w + x] = Float(v1)
                }
            }
        }
    }
    return FloatImage(width: w, height: h, pixels: out)
}
