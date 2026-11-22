// Sending finished images to a printer through CUPS (`lp`). Mirrors openquad/printing.py.
// This is the composite path: the image is already rendered and goes through the
// printer's normal driver. (The app will also offer the macOS print dialog.)

import Foundation

public struct PrintError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// One of a printer's driver options from its PPD, e.g. CNIJMediaType "Media Type".
/// `choices` are (value, name) pairs; `defaultValue` is the driver's own choice.
public struct PrinterOption: Sendable, Equatable {
    public let keyword: String
    public let label: String
    public let choices: [Choice]
    public let defaultValue: String?

    public struct Choice: Sendable, Equatable, Hashable {
        public let value: String
        public let name: String
        public init(value: String, name: String) {
            self.value = value
            self.name = name
        }
    }

    public init(keyword: String, label: String, choices: [Choice], defaultValue: String? = nil) {
        self.keyword = keyword
        self.label = label
        self.choices = choices
        self.defaultValue = defaultValue
    }

    /// The name shown for a value, e.g. "28" -> "Matte Photo Paper".
    public func name(of value: String) -> String { choices.first { $0.value == value }?.name ?? value }
}

public struct PrintJob: Sendable {
    public let path: String
    public let printer: String
    public let paper: String
    /// Makes the image print at its real size (pixels / ppi inches).
    public let ppi: Double
    /// The page turned on its side: the image prints rotated onto it.
    public let landscape: Bool
    public let copies: Int
    public let title: String?
    /// Extra `lp -o name=value` driver options.
    public let options: [(String, String)]

    public init(path: String, printer: String, paper: String = "Letter", ppi: Double = 300, landscape: Bool = false, copies: Int = 1,
                title: String? = nil, options: [(String, String)] = []) throws {
        guard !printer.isEmpty, !printer.contains(where: \.isWhitespace) else {
            throw PrintError(description: "invalid printer name: \(pyRepr(printer))")
        }
        guard copies >= 1 else { throw PrintError(description: "copies must be at least 1, got \(copies)") }
        guard ppi > 0 else { throw PrintError(description: "ppi must be positive, got \(ppi)") }
        self.path = path
        self.printer = printer
        self.paper = paper
        self.ppi = ppi
        self.landscape = landscape
        self.copies = copies
        self.title = title
        self.options = options
    }

    /// The `lp` command line for this job.
    public func command() -> [String] {
        var command = ["lp", "-d", printer, "-n", String(copies), "-o", "PageSize=\(paper)",
                       "-o", "ppi=\(pyRound(ppi))", "-t", title ?? (path as NSString).lastPathComponent]
        if landscape { command += ["-o", "landscape"] }
        for (name, value) in options { command += ["-o", "\(name)=\(value)"] }
        command.append(path)
        return command
    }
}

public enum Printing {
    /// command -> (exit status, stdout, stderr).
    public typealias Runner = ([String]) throws -> (Int32, String, String)

    /// Run a CUPS command, capturing its output.
    public static func runCommand(_ command: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            throw PrintError(description: "\(pyRepr(command[0])) not found; CUPS printing tools are required")
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile(), stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 127 {
            throw PrintError(description: "\(pyRepr(command[0])) not found; CUPS printing tools are required")
        }
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    /// Submit the job and return the CUPS job id (e.g. "Canon_MG3600_series-3144").
    public static func send(_ job: PrintJob, runner: Runner = runCommand) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: job.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PrintError(description: "file not found: \(job.path)")
        }
        let (status, stdout, stderr) = try runner(job.command())
        guard status == 0 else {
            throw PrintError(description: "lp failed: \((stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let match = stdout.firstMatch(of: /request id is (\S+)/) else {
            throw PrintError(description: "lp gave no job id: \(pyRepr(stdout.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        return String(match.1)
    }

    /// Where CUPS keeps each printer's PPD (its driver options and their names).
    public static let ppdFolder = URL(fileURLWithPath: "/etc/cups/ppd")

    /// The driver options for the media (paper) type and the print quality, by keyword, most
    /// likely first: IPP Everywhere / AirPrint, Canon, Epson, HP, Brother. A printer whose
    /// options use none of these is matched by the option's name instead.
    public static let mediaKeywords = ["MediaType", "CNIJMediaType", "EPIJ_Medi", "HPMediaType", "BRMediaType"]
    public static let qualityKeywords = ["cupsPrintQuality", "CNIJPrintQuality", "EPIJ_Qual", "HPPrintQuality",
                                         "OutputMode", "BRPrintQuality"]

    /// Names for the standard IPP media types, which AirPrint and IPP Everywhere PPDs list
    /// without names of their own.
    public static let ippMediaNames = [
        "any": "Any",
        "stationery": "Plain paper",
        "stationery-coated": "Coated paper",
        "stationery-inkjet": "Inkjet paper",
        "stationery-heavyweight": "Heavyweight paper",
        "stationery-lightweight": "Lightweight paper",
        "photographic": "Photo paper",
        "photographic-glossy": "Glossy photo paper",
        "photographic-high-gloss": "High-gloss photo paper",
        "photographic-semi-gloss": "Semi-gloss photo paper",
        "photographic-satin": "Satin photo paper",
        "photographic-matte": "Matte photo paper",
        "transparency": "Transparency",
        "envelope": "Envelope",
        "labels": "Labels",
        "cardstock": "Card stock",
    ]

    /// The pick-one options in a PPD, in order, with their choices and defaults.
    public static func parsePPD(_ text: String) -> [PrinterOption] {
        var options = [(keyword: String, label: String, choices: [PrinterOption.Choice])]()
        var defaults = [String: String]()
        var current: (keyword: String, label: String)?
        var choices = [PrinterOption.Choice]()
        for line in text.splitLines() {
            if let match = line.firstMatch(of: /^\*Default([^\s:]+):\s*(\S+)/) {
                defaults[String(match.1)] = String(match.2)
            }
            guard let open = current else {
                if let match = line.firstMatch(of: /^\*OpenUI \*([^\s\/:]+)(?:\/([^:]*))?:\s*(\S+)/), match.3 == "PickOne" {
                    let keyword = String(match.1)
                    current = (keyword, (match.2.map(String.init) ?? keyword).trimmingCharacters(in: .whitespaces))
                    choices = []
                }
                continue
            }
            if line.hasPrefix("*CloseUI") {
                options.append((open.keyword, open.label, choices))
                current = nil
                continue
            }
            let prefix = "*\(open.keyword) "
            if line.hasPrefix(prefix), let colon = line.firstIndex(of: ":") {
                let head = line[line.index(line.startIndex, offsetBy: prefix.count)..<colon]
                let parts = head.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                let value = parts[0].trimmingCharacters(in: .whitespaces)
                let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                if !value.isEmpty {
                    choices.append(PrinterOption.Choice(value: value, name: name.isEmpty ? ippMediaNames[value] ?? value : name))
                }
            }
        }
        return options.filter { !$0.choices.isEmpty }.map {
            PrinterOption(keyword: $0.keyword, label: $0.label, choices: $0.choices, defaultValue: defaults[$0.keyword])
        }
    }

    private static func find(_ options: [PrinterOption], keywords: [String], words: [String]) -> PrinterOption? {
        for keyword in keywords { if let option = options.first(where: { $0.keyword == keyword }) { return option } }
        return options.first { option in words.contains { option.label.lowercased().contains($0) } }
    }

    /// The printer's media type and print quality options (nil where it has none).
    public static func mediaAndQuality(_ options: [PrinterOption]) -> (media: PrinterOption?, quality: PrinterOption?) {
        let media = find(options, keywords: mediaKeywords, words: ["media type", "paper type"])
        let rest = options.filter { $0.keyword != media?.keyword }
        return (media, find(rest, keywords: qualityKeywords, words: ["quality"]))
    }

    /// A CUPS printer's driver options, from its PPD; none if it has no PPD to read.
    public static func printerOptions(_ printer: String, folder: URL = ppdFolder) throws -> [PrinterOption] {
        guard !printer.isEmpty, !printer.contains("/"), !printer.contains(where: \.isWhitespace) else {
            throw PrintError(description: "invalid printer name: \(pyRepr(printer))")
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(printer).ppd")) else { return [] }
        return parsePPD(String(decoding: data, as: UTF8.self))
    }

    /// Names of the CUPS printers set up on this computer.
    public static func listPrinters(runner: Runner = runCommand) throws -> [String] {
        let (status, stdout, stderr) = try runner(["lpstat", "-e"])
        guard status == 0 else {
            throw PrintError(description: "lpstat failed: \((stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return stdout.splitLines().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
