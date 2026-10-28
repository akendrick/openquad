// Paper sizes and fitting an image to the page. Mirrors openquad/paper.py and
// openquad/negative.py negative_ppi.

public enum Paper {
    /// (width, height) in inches, portrait. Names match the CUPS PageSize names.
    public static let sizes: [String: (Double, Double)] = [
        "Letter": (8.5, 11.0),
        "Legal": (8.5, 14.0),
        "A4": (8.27, 11.69),
        "A5": (5.83, 8.27),
        "4x6": (4.0, 6.0),
        "5x7": (5.0, 7.0),
        "8x10": (8.0, 10.0),
    ]
    public static let defaultMargin = 0.5

    public struct FitError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The resolution that makes the image as large as fits within the page's margins.
    public static func fitPPI(width: Int, height: Int, paper: String, margin: Double = defaultMargin) throws -> Double {
        try ppi(width: width, height: height, paper: paper, margin: margin, safeEdge: 0)
    }

    /// The resolution at which a photo plus its safe edge fit within the margins.
    public static func negativePPI(width: Int, height: Int, paper: String, safeEdge: Double, margin: Double = defaultMargin) throws -> Double {
        try ppi(width: width, height: height, paper: paper, margin: margin, safeEdge: safeEdge)
    }

    static func ppi(width: Int, height: Int, paper: String, margin: Double, safeEdge: Double) throws -> Double {
        guard let (paperWidth, paperHeight) = sizes[paper] else { throw FitError(description: "unknown paper \(paper)") }
        guard width >= 1, height >= 1 else { throw FitError(description: "image has no pixels") }
        let roomW = paperWidth - 2 * margin - 2 * safeEdge
        let roomH = paperHeight - 2 * margin - 2 * safeEdge
        guard roomW > 0, roomH > 0 else { throw FitError(description: "no room on \(paper) with these margins") }
        return max(Double(width) / roomW, Double(height) / roomH)
    }

    /// The box (width, height) turned to match the image: its long side along the image's.
    public static func oriented(_ box: (Double, Double), width: Int, height: Int) -> (Double, Double) {
        let long = max(box.0, box.1), short = min(box.0, box.1)
        return width > height ? (long, short) : (short, long)
    }

    /// The resolution that makes the image, plus `border` inches round it, as large as fits
    /// within a `box` of (width, height) inches, turned to match the image.
    public static func boxPPI(width: Int, height: Int, box: (Double, Double), border: Double = 0) throws -> Double {
        guard width >= 1, height >= 1 else { throw FitError(description: "image has no pixels") }
        guard min(box.0, box.1) > 0 else {
            throw FitError(description: "the size must be positive, got \(String(format: "%g x %g", box.0, box.1)) in")
        }
        let (boxWidth, boxHeight) = oriented(box, width: width, height: height)
        let roomW = boxWidth - 2 * border, roomH = boxHeight - 2 * border
        guard roomW > 0, roomH > 0 else {
            throw FitError(description: "no room inside \(String(format: "%g x %g", boxWidth, boxHeight)) in with a "
                           + "\(String(format: "%g", border)) in edge")
        }
        return max(Double(width) / roomW, Double(height) / roomH)
    }
}
