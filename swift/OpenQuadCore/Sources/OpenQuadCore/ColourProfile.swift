// Building a printer's colour profile from measurements of the colour target (phase 2).
// Mirrors openquad/colour_profile.py: a smoothed 9 x 9 x 9 forward model (RGB sent to
// L*a*b* relative to the paper), its inverse by search, and an ICC v2 output profile.
// The fits use LAPACK, so results agree with Python's to rounding, not to the bit.

import Accelerate
import Foundation

public struct ProfileError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum ColourProfiles {
    public static let lattice = 9
    public static let smoothing = [0.0001, 0.0003, 0.001, 0.003, 0.01, 0.03]
    public static let folds = 5
    public static let a2bGrid = 17
    public static let b2aGrid = 33
    public static let searchGrid = 12
    public static let gamutLimit = 1.0  // ΔE76 beyond which a colour counts as out of gamut
    static let foldSeed: UInt32 = 11
}

// MARK: - forward model

/// RGB sent (0-1) to L*a*b* measured, relative to the paper.
public struct ForwardModel: Sendable, Equatable {
    /// (n³ x 3) L*a*b* at each lattice point, flat, red slowest.
    public let nodes: [Double]
    public let size: Int
    public let smoothing: Double
    public let paperXYZ: [Double]

    public init(nodes: [Double], smoothing: Double = 0, paperXYZ: [Double] = Colour.d50White) {
        self.nodes = nodes
        size = Int((cbrt(Double(nodes.count / 3))).rounded())
        self.smoothing = smoothing
        self.paperXYZ = paperXYZ
    }

    /// The 8 lattice nodes round a point, and their weights.
    @inline(__always)
    static func corners(_ r: Double, _ g: Double, _ b: Double, _ n: Int) -> ([Int], [Double]) {
        var lower = [0, 0, 0], frac = [0.0, 0.0, 0.0]
        for (axis, v) in [r, g, b].enumerated() {
            let scaled = clip(v, 0, 1) * Double(n - 1)
            lower[axis] = min(Int(scaled.rounded(.down)), n - 2)
            frac[axis] = scaled - Double(lower[axis])
        }
        var index: [Int] = [], weight: [Double] = []
        for i in 0...1 { for j in 0...1 { for k in 0...1 {
            index.append(((lower[0] + i) * n + lower[1] + j) * n + lower[2] + k)
            weight.append((i == 1 ? frac[0] : 1 - frac[0]) * (j == 1 ? frac[1] : 1 - frac[1]) * (k == 1 ? frac[2] : 1 - frac[2]))
        } } }
        return (index, weight)
    }

    /// L*a*b* for one RGB, without allocating (the inverse calls this millions of times).
    @inline(__always)
    public func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let n = size, m = Double(n - 1)
        let sr = min(max(r, 0), 1) * m, sg = min(max(g, 0), 1) * m, sb = min(max(b, 0), 1) * m
        let lr = min(Int(sr), n - 2), lg = min(Int(sg), n - 2), lb = min(Int(sb), n - 2)
        let fr = sr - Double(lr), fg = sg - Double(lg), fb = sb - Double(lb)
        return nodes.withUnsafeBufferPointer { p in
            var l = 0.0, a = 0.0, bb = 0.0
            for i in 0...1 {
                let wr = i == 1 ? fr : 1 - fr
                for j in 0...1 {
                    let wg = j == 1 ? fg : 1 - fg
                    for k in 0...1 {
                        let w = wr * wg * (k == 1 ? fb : 1 - fb)
                        let at = (((lr + i) * n + lg + j) * n + lb + k) * 3
                        l += p[at] * w
                        a += p[at + 1] * w
                        bb += p[at + 2] * w
                    }
                }
            }
            return (l, a, bb)
        }
    }

    public func lab(_ rgb: [Double]) -> [Double] {
        let (l, a, b) = lab(rgb[0], rgb[1], rgb[2])
        return [l, a, b]
    }

    public func json() throws -> String {
        try jsonCompact([
            "kind": "openquad colour model", "version": 1, "smoothing": smoothing, "paper_xyz": paperXYZ,
            "nodes": stride(from: 0, to: nodes.count, by: 3).map { [npRound(nodes[$0], 4), npRound(nodes[$0 + 1], 4), npRound(nodes[$0 + 2], 4)] },
        ] as [String: Any])
    }

    public static func decode(_ data: Data) throws -> ForwardModel {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], d["kind"] as? String == "openquad colour model",
              let nodes = d["nodes"] as? [[NSNumber]], let paper = d["paper_xyz"] as? [NSNumber] else {
            throw ProfileError(description: "not an OpenQuad colour model")
        }
        return ForwardModel(nodes: nodes.flatMap { $0.map(\.doubleValue) }, smoothing: (d["smoothing"] as? NSNumber)?.doubleValue ?? 0,
                            paperXYZ: paper.map(\.doubleValue))
    }
}

// MARK: - fitting

/// Solve A x = B for square A (n x n, symmetric here) and B (n x k), as numpy.linalg.solve.
func solveLinear(_ a: [Double], _ b: [[Double]], n: Int) throws -> [[Double]] {
    let k = b.first?.count ?? 0
    var matrix = a  // symmetric, so row- and column-major agree
    var rhs = [Double](repeating: 0, count: n * k)
    for i in 0..<n { for c in 0..<k { rhs[c * n + i] = b[i][c] } }
    var nn = __LAPACK_int(n), nrhs = __LAPACK_int(k), lda = __LAPACK_int(n), ldb = __LAPACK_int(n), info = __LAPACK_int(0)
    var pivots = [__LAPACK_int](repeating: 0, count: n)
    dgesv_(&nn, &nrhs, &matrix, &lda, &pivots, &rhs, &ldb, &info)
    guard info == 0 else { throw ProfileError(description: "the model's equations are singular") }
    return (0..<n).map { i in (0..<k).map { rhs[$0 * n + i] } }
}

enum Lattice {
    nonisolated(unsafe) static var penalties: [Int: [Double]] = [:]
    static let lock = NSLock()

    /// RᵀR for R the second differences along each axis of an n³ lattice (dense, n³ x n³).
    static func penalty(_ n: Int) -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        if let p = penalties[n] { return p }
        let size = n * n * n
        var p = [Double](repeating: 0, count: size * size)
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (i * n + j) * n + k }
        let coefficients = [1.0, -2.0, 1.0]
        for axis in 0..<3 {
            for i in 1..<(n - 1) {
                for u in 0..<n {
                    for v in 0..<n {
                        let nodes = (-1...1).map { d -> Int in
                            switch axis {
                            case 0: return index(i + d, u, v)
                            case 1: return index(u, i + d, v)
                            default: return index(u, v, i + d)
                            }
                        }
                        for x in 0..<3 { for y in 0..<3 { p[nodes[x] * size + nodes[y]] += coefficients[x] * coefficients[y] } }
                    }
                }
            }
        }
        penalties[n] = p
        return p
    }

    /// Lattice nodes (n³, k) fitted to values (points, k) at RGB points, with smoothing.
    static func fit(_ rgb: [[Double]], _ values: [[Double]], smoothing: Double, n: Int) throws -> [[Double]] {
        let size = n * n * n, k = values.first?.count ?? 0
        var normal = penalty(n).map { $0 * smoothing * Double(rgb.count) }
        var right = [[Double]](repeating: [Double](repeating: 0, count: k), count: size)
        for (point, value) in zip(rgb, values) {
            let (index, weight) = ForwardModel.corners(point[0], point[1], point[2], n)
            for x in 0..<8 {
                for y in 0..<8 { normal[index[x] * size + index[y]] += weight[x] * weight[y] }
                for c in 0..<k { right[index[x]][c] += weight[x] * value[c] }
            }
        }
        return try solveLinear(normal, right, n: size)
    }

    static func predict(_ nodes: [[Double]], _ rgb: [Double], n: Int) -> [Double] {
        let (index, weight) = ForwardModel.corners(rgb[0], rgb[1], rgb[2], n)
        return (0..<nodes[0].count).map { c in (0..<8).reduce(0.0) { $0 + nodes[index[$1]][c] * weight[$1] } }
    }
}

extension ColourProfiles {
    /// numpy: default_rng(11).permutation(count), dealt into five folds.
    static func folds(_ count: Int) -> [[Int]] {
        var rng = NumpyRandom(seed: foldSeed)
        let order = rng.permutation(count)
        return (0..<folds).map { f in stride(from: f, to: count, by: folds).map { order[$0] } }
    }

    /// Each patch's ΔE00 when predicted by a model fitted without it (five folds).
    public static func heldOutErrors(_ rgb: [[Double]], _ lab: [[Double]], smoothing: Double, n: Int = lattice) throws -> [Double] {
        var errors = [Double](repeating: 0, count: rgb.count)
        for fold in folds(rgb.count) {
            let out = Set(fold)
            let keep = rgb.indices.filter { !out.contains($0) }
            let nodes = try Lattice.fit(keep.map { rgb[$0] }, keep.map { lab[$0] }, smoothing: smoothing, n: n)
            for i in fold { errors[i] = Colour.deltaE2000(Lattice.predict(nodes, rgb[i], n: n), lab[i]) }
        }
        return errors
    }

    /// Lattice nodes, flat (n³ x k), fitted to values at RGB points.
    public static func fitLattice(_ rgb: [[Double]], _ values: [[Double]], smoothing: Double, n: Int = lattice) throws -> [Double] {
        try Lattice.fit(rgb, values, smoothing: smoothing, n: n).flatMap { $0 }
    }

    /// The forward model and each patch's held-out ΔE00. Without `smoothing`, each of
    /// `smoothing` is tried and the one whose held-out predictions are best is kept.
    public static func fitForward(_ rgb: [[Double]], _ lab: [[Double]], smoothing chosen: Double? = nil, n: Int = lattice,
                                  paperXYZ: [Double]? = nil) throws -> (ForwardModel, [Double]) {
        guard rgb.count >= 4 * n else {
            throw ProfileError(description: "need at least \(4 * n) patches to fit the model, got \(rgb.count)")
        }
        var best: (errors: [Double], smoothing: Double)?
        for s in chosen.map({ [$0] }) ?? smoothing {
            let errors = try heldOutErrors(rgb, lab, smoothing: s, n: n)
            if best == nil || npMean(errors) < npMean(best!.errors) { best = (errors, s) }
        }
        let nodes = try fitLattice(rgb, lab, smoothing: best!.smoothing, n: n)
        return (ForwardModel(nodes: nodes, smoothing: best!.smoothing, paperXYZ: paperXYZ ?? Colour.d50White), best!.errors)
    }

    // MARK: inverse

    /// The deepest neutral the printer makes, as XYZ relative to the paper (D50 white).
    public static func blackPoint(_ model: ForwardModel) -> [Double] {
        let lightness = model.lab(0, 0, 0).0
        let darkest = linspace(0, 0.3, 31).map { model.lab($0, $0, $0).0 }.min()!
        let y = Colour.labToXYZ([min(lightness, darkest), 0, 0], white: Colour.d50White)[1]
        return Colour.d50White.map { y * $0 }
    }

    /// Scale colours towards the printer's black so L* 0 lands on it (Adobe's black-point
    /// compensation: linear in XYZ, white kept).
    public static func compensateBlack(_ lab: [Double], black: [Double]) -> [Double] {
        let xyz = Colour.labToXYZ(lab, white: Colour.d50White)
        let mapped = (0..<3).map { xyz[$0] * (1 - black[$0] / Colour.d50White[$0]) + black[$0] }
        return Colour.xyzToLab(mapped, white: Colour.d50White)
    }

    /// The RGB (0-1) whose print comes closest to each L*a*b* (ΔE76): the nearest of a
    /// coarse grid, then refined by damped Gauss-Newton steps kept inside the RGB cube.
    public static func invert(_ model: ForwardModel, _ wanted: [[Double]], steps: Int = 8) -> [[Double]] {
        let levels = linspace(0, 1, searchGrid)
        var grid: [Double] = [], gridLab: [Double] = []
        for r in levels { for g in levels { for b in levels {
            grid += [r, g, b]
            let (l, a, bb) = model.lab(r, g, b)
            gridLab += [l, a, bb]
        } } }
        let count = levels.count * levels.count * levels.count
        let norms = (0..<count).map { gridLab[3 * $0] * gridLab[3 * $0] + gridLab[3 * $0 + 1] * gridLab[3 * $0 + 1] + gridLab[3 * $0 + 2] * gridLab[3 * $0 + 2] }
        var start = [[Double]](repeating: [0, 0, 0], count: wanted.count)
        let chunk = 4096
        var products = [Double](repeating: 0, count: chunk * count), row = [Double](repeating: 0, count: count)
        for first in stride(from: 0, to: wanted.count, by: chunk) {
            let rows = min(chunk, wanted.count - first)
            let block = wanted[first..<(first + rows)].flatMap { $0 }
            cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, __LAPACK_int(rows), __LAPACK_int(count), 3, 1, block, 3,
                        gridLab, 3, 0, &products, __LAPACK_int(count))
            for i in 0..<rows {
                products.withUnsafeBufferPointer { p in
                    var minus2 = -2.0
                    vDSP_vsmaD(p.baseAddress! + i * count, 1, &minus2, norms, 1, &row, 1, vDSP_Length(count))
                }
                var smallest = 0.0, at: vDSP_Length = 0
                vDSP_minviD(row, 1, &smallest, &at, vDSP_Length(count))
                let j = Int(at)
                start[first + i] = [grid[3 * j], grid[3 * j + 1], grid[3 * j + 2]]
            }
        }
        return zip(start, wanted).map { refine(model, $0, $1, steps: steps) }
    }

    /// Damped Gauss-Newton (Levenberg-Marquardt) steps from `rgb` towards `wanted`, kept
    /// inside the RGB cube. Written without arrays: the tables call it 70,000 times.
    static func refine(_ model: ForwardModel, _ start: [Double], _ wanted: [Double], steps: Int) -> [Double] {
        let h = 1e-3
        var r = start[0], g = start[1], b = start[2]
        let (wl, wa, wb) = (wanted[0], wanted[1], wanted[2])
        for _ in 0..<steps {
            let here = model.lab(r, g, b)
            let e0 = wl - here.0, e1 = wa - here.1, e2 = wb - here.2
            // Columns of the Jacobian: d(L*, a*, b*) / d(r), d(g), d(b).
            let sr = r + h <= 1 ? h : -h, sg = g + h <= 1 ? h : -h, sb = b + h <= 1 ? h : -h
            let pr = model.lab(r + sr, g, b), pg = model.lab(r, g + sg, b), pb = model.lab(r, g, b + sb)
            let j00 = (pr.0 - here.0) / sr, j10 = (pr.1 - here.1) / sr, j20 = (pr.2 - here.2) / sr
            let j01 = (pg.0 - here.0) / sg, j11 = (pg.1 - here.1) / sg, j21 = (pg.2 - here.2) / sg
            let j02 = (pb.0 - here.0) / sb, j12 = (pb.1 - here.1) / sb, j22 = (pb.2 - here.2) / sb
            // (JᵀJ + 1e-3 I) delta = Jᵀ e
            let a00 = j00 * j00 + j10 * j10 + j20 * j20 + 1e-3, a01 = j00 * j01 + j10 * j11 + j20 * j21
            let a02 = j00 * j02 + j10 * j12 + j20 * j22, a11 = j01 * j01 + j11 * j11 + j21 * j21 + 1e-3
            let a12 = j01 * j02 + j11 * j12 + j21 * j22, a22 = j02 * j02 + j12 * j12 + j22 * j22 + 1e-3
            let v0 = j00 * e0 + j10 * e1 + j20 * e2, v1 = j01 * e0 + j11 * e1 + j21 * e2, v2 = j02 * e0 + j12 * e1 + j22 * e2
            let c00 = a11 * a22 - a12 * a12, c01 = a02 * a12 - a01 * a22, c02 = a01 * a12 - a02 * a11
            let det = a00 * c00 + a01 * c01 + a02 * c02
            guard det != 0, det.isFinite else { break }
            let c11 = a00 * a22 - a02 * a02, c12 = a01 * a02 - a00 * a12, c22 = a00 * a11 - a01 * a01
            let d0 = (c00 * v0 + c01 * v1 + c02 * v2) / det
            let d1 = (c01 * v0 + c11 * v1 + c12 * v2) / det
            let d2 = (c02 * v0 + c12 * v1 + c22 * v2) / det
            let tr = min(max(r + d0, 0), 1), tg = min(max(g + d1, 0), 1), tb = min(max(b + d2, 0), 1)
            let got = model.lab(tr, tg, tb)
            let trialError = (wl - got.0) * (wl - got.0) + (wa - got.1) * (wa - got.1) + (wb - got.2) * (wb - got.2)
            if trialError < e0 * e0 + e1 * e1 + e2 * e2 { (r, g, b) = (tr, tg, tb) }
        }
        return [r, g, b]
    }
}

// MARK: - ICC

extension ColourProfiles {
    /// L*a*b* as ICC v2 16-bit (L* 100 = 0xFF00, a*/b* 0 = 0x8000).
    public static func encodeLab(_ lab: [Double]) -> [UInt16] {
        [UInt16(rint(clip(lab[0], 0, 100) * 652.80))]
            + lab[1...2].map { UInt16(rint((clip($0, -128, 255.0 / 256 + 127) + 128) * 256)) }
    }

    public static func decodeLab(_ code: [Double]) -> [Double] { [code[0] / 652.80, code[1] / 256 - 128, code[2] / 256 - 128] }

    /// The L*a*b* at each point of a grid over the ICC v2 encoding, L* slowest.
    static func labGrid(_ grid: Int) -> [[Double]] {
        let codes = linspace(0, 65535, grid)
        return codes.flatMap { l in codes.flatMap { a in codes.map { b in decodeLab([l, a, b]) } } }
    }

    static func s15(_ value: Double) -> [UInt8] { be32(UInt32(bitPattern: Int32(pyRound(value * 65536)))) }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func ascii(_ s: String) -> [UInt8] { s.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : 0x3f } }

    static func xyzTag(_ xyz: [Double]) -> [UInt8] { Array("XYZ ".utf8) + [0, 0, 0, 0] + xyz.flatMap(s15) }
    static func textTag(_ text: String) -> [UInt8] { Array("text".utf8) + [0, 0, 0, 0] + ascii(text) + [0] }

    static func descTag(_ text: String) -> [UInt8] {
        let bytes = ascii(text) + [0]
        return Array("desc".utf8) + [0, 0, 0, 0] + be32(UInt32(bytes.count)) + bytes + be32(0) + be32(0) + [0, 0, 0]
            + [UInt8](repeating: 0, count: 67)
    }

    /// An mft2 (lut16Type) tag with straight input and output curves.
    static func lut16(_ table: [[UInt16]], inputs: Int, grid: Int) -> [UInt8] {
        let outputs = table.first?.count ?? 0
        let identity = [1.0, 0, 0, 0, 1, 0, 0, 0, 1].flatMap(s15)
        let straight = be16(0) + be16(0xFFFF)
        var out = Array("mft2".utf8) + [0, 0, 0, 0] + [UInt8(inputs), UInt8(outputs), UInt8(grid), 0] + identity + be16(2) + be16(2)
        for _ in 0..<inputs { out += straight }
        out.reserveCapacity(out.count + table.count * outputs * 2 + outputs * 4)
        for entry in table { for v in entry { out += be16(v) } }
        for _ in 0..<outputs { out += straight }
        return out
    }
}

/// What goes in the profile (and what the report is worked out from).
public struct ProfileTables: Sendable {
    public let a2b: [[Double]]  // L*a*b* for each point of an RGB grid
    public let b2aPerceptual: [[Double]]  // RGB 0-1 for each point of a L*a*b* grid
    public let b2aColourimetric: [[Double]]
    public let gamut: [Double]  // ΔE76 of the nearest printable colour

    public static func build(_ model: ForwardModel) -> ProfileTables {
        let levels = linspace(0, 1, ColourProfiles.a2bGrid)
        let a2b = levels.flatMap { r in levels.flatMap { g in levels.map { b in model.lab([r, g, b]) } } }
        let wanted = ColourProfiles.labGrid(ColourProfiles.b2aGrid)
        let colourimetric = ColourProfiles.invert(model, wanted)
        let gamut = zip(colourimetric, wanted).map { Colour.deltaE76(model.lab($0), $1) }
        let black = ColourProfiles.blackPoint(model)
        let perceptual = ColourProfiles.invert(model, wanted.map { ColourProfiles.compensateBlack($0, black: black) })
        return ProfileTables(a2b: a2b, b2aPerceptual: perceptual, b2aColourimetric: colourimetric, gamut: gamut)
    }
}

extension ColourProfiles {
    /// An ICC v2 output profile (RGB device, L*a*b* PCS) for the model.
    public static func iccProfile(_ model: ForwardModel, description: String, tables: ProfileTables? = nil,
                                  copyright: String = "No copyright; made with OpenQuad", created: Date = Date()) -> Data {
        let tables = tables ?? ProfileTables.build(model)
        let a2b = lut16(tables.a2b.map(encodeLab), inputs: 3, grid: a2bGrid)
        func device(_ rgb: [Double]) -> [UInt16] { rgb.map { UInt16(rint(clip($0, 0, 1) * Double(maxValue))) } }
        let perceptual = lut16(tables.b2aPerceptual.map(device), inputs: 3, grid: b2aGrid)
        let colourimetric = lut16(tables.b2aColourimetric.map(device), inputs: 3, grid: b2aGrid)
        let gamut = lut16(tables.gamut.map { device([clip(($0 - gamutLimit) / 9.0, 0, 1)]) }, inputs: 3, grid: b2aGrid)
        let black = zip(blackPoint(model), zip(model.paperXYZ, Colour.d50White)).map { $0 * $1.0 / $1.1 }
        let tags: [(String, [UInt8])] = [
            ("desc", descTag(description)), ("cprt", textTag(copyright)), ("wtpt", xyzTag(model.paperXYZ)), ("bkpt", xyzTag(black)),
            ("A2B0", a2b), ("A2B1", a2b), ("A2B2", a2b), ("B2A0", perceptual), ("B2A1", colourimetric), ("B2A2", perceptual),
            ("gamt", gamut),
        ]
        // Tags that are the same bytes share one copy.
        let offset = 128 + 4 + 12 * tags.count
        var body: [UInt8] = [], placed: [[UInt8]: (Int, Int)] = [:]
        var table = be32(UInt32(tags.count))
        for (signature, data) in tags {
            if placed[data] == nil {
                placed[data] = (offset + body.count, data.count)
                body += data + [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
            }
            let (start, size) = placed[data]!
            table += Array(signature.utf8) + be32(UInt32(start)) + be32(UInt32(size))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let when = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: created)
        var header = be32(UInt32(128 + table.count + body.count)) + [0, 0, 0, 0] + be32(0x0210_0000) + Array("prtrRGB Lab ".utf8)
        for part in [when.year, when.month, when.day, when.hour, when.minute, when.second] { header += be16(UInt16(part ?? 0)) }
        header += Array("acsp".utf8) + Array("APPL".utf8) + [UInt8](repeating: 0, count: 4 + 4 + 4 + 8) + be32(0)
        header += Array(xyzTag(Colour.d50White).dropFirst(8)) + Array("OpQd".utf8)
        header += [UInt8](repeating: 0, count: 128 - header.count)
        return Data(header + table + body)
    }
}

// MARK: - building, with a report

public struct ProfileReport: Sendable {
    public let model: ForwardModel
    public let tables: ProfileTables
    public let fitted: [Double]  // each patch's ΔE00 against the model
    public let heldOut: [Double]  // ... against a model fitted without it
    public let neutralCast: [Double]  // C* of the print of each grey L* 10-95, through the profile
    public let spread: [[Double]]?  // each print's ΔE00 from the mean, if several
    public let prints: Int

    public func summary() -> String {
        let black = model.lab([0, 0, 0])
        let chroma = ColourTargets.hues.map { let l = model.lab($0); return hypot(l[1], l[2]) }
        var lines = [
            "Model from \(fitted.count) patches\(prints > 1 ? ", averaged over \(prints) prints" : "") "
                + "(smoothing \(String(format: "%g", model.smoothing))).",
            String(format: "Fit: mean %.2f, 95%% %.2f ΔE00.", npMean(fitted), percentile(fitted, [95])[0]),
            String(format: "Patches left out: mean %.2f, 95%% %.2f, worst %.2f ΔE00.", npMean(heldOut),
                   percentile(heldOut, [95])[0], heldOut.max() ?? 0),
            String(format: "Black: L* %.1f, a* %.1f, b* %.1f; primaries reach chroma %.0f to %.0f.", black[0], black[1], black[2],
                   chroma.min()!, chroma.max()!),
            String(format: "Greys through the profile: worst cast %.2f (mean %.2f).", neutralCast.max() ?? 0, npMean(neutralCast)),
        ]
        if let spread {
            let all = spread.flatMap { $0 }
            lines.append(String(format: "Between prints: mean %.2f, worst %.2f ΔE00.", npMean(all), all.max() ?? 0))
        }
        return lines.joined(separator: "\n")
    }

    /// Fit the forward model to one or more prints' measurements and work out the tables.
    public static func build(_ measurements: [ColourMeasurement], smoothing: Double? = nil) throws -> ProfileReport {
        guard let first = measurements.first else { throw ProfileError(description: "no measurements") }
        guard measurements.allSatisfy({ $0.sent == first.sent }) else {
            throw ProfileError(description: "the measurements are of different targets")
        }
        let count = Double(measurements.count)
        let lab = first.lab.indices.map { i in (0..<3).map { c in measurements.reduce(0.0) { $0 + $1.lab[i][c] } / count } }
        let paper = (0..<3).map { c in measurements.reduce(0.0) { $0 + $1.paperXYZ[c] } / count }
        let spread = measurements.count > 1 ? measurements.map { m in zip(m.lab, lab).map { Colour.deltaE2000($0, $1) } } : nil
        let rgb = first.sent.map { $0.map { Double($0) / Double(maxValue) } }
        let (model, heldOut) = try ColourProfiles.fitForward(rgb, lab, smoothing: smoothing, paperXYZ: paper)
        let fitted = zip(rgb, lab).map { Colour.deltaE2000(model.lab($0), $1) }
        let black = ColourProfiles.blackPoint(model)
        let greys = linspace(10, 95, 18).map { ColourProfiles.compensateBlack([$0, 0, 0], black: black) }
        let cast = ColourProfiles.invert(model, greys).map { let l = model.lab($0); return hypot(l[1], l[2]) }
        return ProfileReport(model: model, tables: ProfileTables.build(model), fitted: fitted, heldOut: heldOut,
                             neutralCast: cast, spread: spread, prints: measurements.count)
    }
}
