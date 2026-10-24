// Read and write `.quad` curve files. Mirrors openquad/quadfile.py.
//
//     ## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK
//     # comment lines
//     0 ... (256 integers 0-65535 per channel, in header order)
//
// Comment and blank lines stay with the channel block that follows them, so a file
// written by `format()` reads back and re-writes byte for byte.

public let quadLevels = 256
public let standardChannels = ["K", "C", "M", "Y", "LC", "LM", "LK", "LLK"]
let headerPrefix = "## QuadToneRIP"

public struct QuadFormatError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public struct QuadCurve: Equatable, Sendable {
    public let channels: [String]
    /// One row of 256 values per channel.
    public let values: [[UInt16]]
    /// Comment/blank lines written before each channel's block.
    public let comments: [[String]]
    /// Comment/blank lines after the last block.
    public let trailer: [String]

    public init(channels: [String], values: [[UInt16]], comments: [[String]]? = nil, trailer: [String] = []) throws {
        guard !channels.isEmpty else { throw QuadFormatError(description: "a curve needs at least one channel") }
        guard Set(channels).count == channels.count else {
            throw QuadFormatError(description: "duplicate channel names: \(channels)")
        }
        for name in channels where name.isEmpty || name.contains(",") || name != name.trimmingWhitespace {
            throw QuadFormatError(description: "invalid channel name: \(name)")
        }
        guard values.count == channels.count, values.allSatisfy({ $0.count == quadLevels }) else {
            throw QuadFormatError(description: "values must be \(channels.count) rows of \(quadLevels)")
        }
        let blocks = comments ?? Array(repeating: [], count: channels.count)
        guard blocks.count == channels.count else {
            throw QuadFormatError(description: "comments must have one entry per channel")
        }
        for line in blocks.flatMap({ $0 }) + trailer
        where !line.trimmingWhitespace.isEmpty && !line.trimmingLeadingWhitespace.hasPrefix("#") {
            throw QuadFormatError(description: "comment lines must start with '#': \(line)")
        }
        self.channels = channels
        self.values = values
        self.comments = blocks
        self.trailer = trailer
    }

    /// A curve with a standard "# <name> curve" comment before each block.
    public static func fromValues(_ channels: [String], _ values: [[UInt16]]) throws -> QuadCurve {
        try QuadCurve(channels: channels, values: values, comments: channels.map { ["# \($0) curve"] })
    }

    public func channel(_ name: String) -> [UInt16]? {
        channels.firstIndex(of: name).map { values[$0] }
    }

    /// Parse the text of a `.quad` file.
    public static func parse(_ text: String) throws -> QuadCurve {
        let lines = text.splitLines()
        guard let header = lines.first, header.hasPrefix(headerPrefix) else {
            throw QuadFormatError(description: "line 1: expected a header starting with '\(headerPrefix)'")
        }
        let namesPart = String(header.dropFirst(headerPrefix.count)).trimmingWhitespace
        var channels = standardChannels
        if !namesPart.isEmpty {
            channels = namesPart.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingWhitespace }
            if channels.contains(where: \.isEmpty) {
                throw QuadFormatError(description: "line 1: empty channel name in '\(namesPart)'")
            }
        }
        var numbers: [UInt16] = []
        var comments: [[String]] = []
        var pending: [String] = []
        for (offset, raw) in lines.dropFirst().enumerated() {
            let lineNumber = offset + 2
            let stripped = raw.trimmingWhitespace
            if stripped.isEmpty || stripped.hasPrefix("#") {
                pending.append(raw)
                continue
            }
            guard let number = Int(stripped) else {
                throw QuadFormatError(description: "line \(lineNumber): expected an integer, got '\(stripped)'")
            }
            guard (0...maxValue).contains(number) else {
                throw QuadFormatError(description: "line \(lineNumber): value \(number) outside 0-\(maxValue)")
            }
            if numbers.count % quadLevels == 0 {
                if numbers.count / quadLevels >= channels.count {
                    throw QuadFormatError(
                        description: "line \(lineNumber): more values than \(channels.count) channels x \(quadLevels)")
                }
                comments.append(pending)
                pending = []
            }
            numbers.append(UInt16(number))
        }
        let expected = channels.count * quadLevels
        guard numbers.count == expected else {
            throw QuadFormatError(description:
                "expected \(expected) values (\(channels.count) channels x \(quadLevels)), found \(numbers.count)")
        }
        let rows = (0..<channels.count).map { Array(numbers[$0 * quadLevels..<($0 + 1) * quadLevels]) }
        return try QuadCurve(channels: channels, values: rows, comments: comments, trailer: pending)
    }

    /// The `.quad` text, with "\n" line endings and a final newline.
    public func format() -> String {
        var out = ["\(headerPrefix) \(channels.joined(separator: ","))"]
        for (block, row) in zip(comments, values) {
            out += block
            out += row.map { String($0) }
        }
        out += trailer
        return out.joined(separator: "\n") + "\n"
    }
}

extension String {
    var trimmingWhitespace: String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }

    var trimmingLeadingWhitespace: String {
        String(drop(while: \.isWhitespace))
    }

    /// Python's str.splitlines() for the line endings that matter here (\n, \r\n, \r).
    func splitLines() -> [String] {
        var lines: [String] = []
        var current = ""
        var previousWasCR = false
        for scalar in unicodeScalars {
            if scalar == "\n" {
                if !previousWasCR { lines.append(current) }
                current = ""
                previousWasCR = false
            } else if scalar == "\r" {
                lines.append(current)
                current = ""
                previousWasCR = true
            } else {
                current.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
