// Sending finished images to a printer through CUPS (`lp`). Mirrors openquad/printing.py.
// This is the composite path: the image is already rendered and goes through the
// printer's normal driver. (The app will also offer the macOS print dialog.)

import Foundation

public struct PrintError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public struct PrintJob: Sendable {
    public let path: String
    public let printer: String
    public let paper: String
    /// Makes the image print at its real size (pixels / ppi inches).
    public let ppi: Double
    public let copies: Int
    public let title: String?
    /// Extra `lp -o name=value` driver options.
    public let options: [(String, String)]

    public init(path: String, printer: String, paper: String = "Letter", ppi: Double = 300, copies: Int = 1,
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
        self.copies = copies
        self.title = title
        self.options = options
    }

    /// The `lp` command line for this job.
    public func command() -> [String] {
        var command = ["lp", "-d", printer, "-n", String(copies), "-o", "PageSize=\(paper)",
                       "-o", "ppi=\(pyRound(ppi))", "-t", title ?? (path as NSString).lastPathComponent]
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

    /// Names of the CUPS printers set up on this computer.
    public static func listPrinters(runner: Runner = runCommand) throws -> [String] {
        let (status, stdout, stderr) = try runner(["lpstat", "-e"])
        guard status == 0 else {
            throw PrintError(description: "lpstat failed: \((stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return stdout.splitLines().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
