// Reading GIMP's own .xcf files, by asking GIMP 3 to merge them into a 16-bit TIFF.
// Mirrors openquad/xcf.py, with the same script: GIMP loads the file, merges the visible
// layers (keeping transparency), turns indexed into RGB and any depth other than 8-bit into
// 16-bit, and saves a TIFF that Photos.load reads as usual. It takes a few seconds.
//
// GIMP is found through OPENQUAD_GIMP (a gimp-console program or a GIMP.app), then GIMP.app
// in /Applications or ~/Applications, then gimp-console on the PATH.

import Foundation

public enum Xcf {
    static let signature = Data("gimp xcf ".utf8)
    static let timeout: TimeInterval = 180  // seconds; a large XCF takes a while
    static let consoleNames = ["gimp-console-3.2", "gimp-console-3.0", "gimp-console-3", "gimp-console"]
    static let needsGIMP = "opening a GIMP .xcf file needs GIMP 3 installed (or export it from GIMP as a TIFF)"

    /// Run inside GIMP's Python; the paths come in through the environment, never in the code.
    static let script = """
    import os
    from gi.repository import Gimp, Gio
    quietly, file = Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path
    image = Gimp.file_load(quietly, file(os.environ["OPENQUAD_XCF_IN"]))
    if image.get_base_type() == Gimp.ImageBaseType.INDEXED:
        image.convert_rgb()
    if image.get_precision() != Gimp.Precision.U8_NON_LINEAR:
        image.convert_precision(Gimp.Precision.U16_NON_LINEAR)
    image.merge_visible_layers(Gimp.MergeType.CLIP_TO_IMAGE)
    Gimp.file_save(quietly, image, file(os.environ["OPENQUAD_XCF_OUT"]), None)
    image.delete()

    """

    /// Where GIMP.app is looked for.
    public static let appFolders = [URL(fileURLWithPath: "/Applications"),
                                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]

    /// Do these first bytes of a file start a GIMP XCF?
    static func isXcf(_ head: Data) -> Bool { head.starts(with: signature) }

    /// Is this file a GIMP XCF (which opens through GIMP, taking a few seconds)?
    public static func isXcf(_ url: URL) -> Bool { isXcf(Photos.head(url, signature.count)) }

    static func console(in app: URL) -> URL? {
        consoleNames.map { app.appendingPathComponent("Contents/MacOS/\($0)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The gimp-console program to run, or nil if GIMP isn't installed.
    public static func findGIMP(environment: [String: String] = ProcessInfo.processInfo.environment,
                                folders: [URL] = appFolders) -> URL? {
        let files = FileManager.default
        if let chosen = environment["OPENQUAD_GIMP"], !chosen.isEmpty {
            let url = URL(fileURLWithPath: chosen)
            if url.pathExtension == "app" { return console(in: url) }
            return files.isExecutableFile(atPath: url.path) ? url : nil
        }
        for folder in folders {
            let apps = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix("GIMP") && $0.hasSuffix(".app") }.sorted(by: >)
            for app in apps {
                if let found = console(in: folder.appendingPathComponent(app)) { return found }
            }
        }
        for name in consoleNames {
            for folder in (environment["PATH"] ?? "").split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent(name)
                if files.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// The arguments: no window, no fonts or brushes to load, run the script, quit.
    static func arguments() -> [String] {
        ["-i", "-d", "-f", "--quit", "--batch-interpreter=python-fu-eval", "-b", script]
    }

    /// Merge the XCF into a TIFF in a new temporary folder and hand it to `body`; the folder is
    /// removed afterwards.
    static func flattened<T>(_ url: URL, gimp: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                             _ body: (URL) throws -> T) throws -> T {
        let name = url.path
        guard let gimp = gimp ?? findGIMP(environment: environment) else {
            throw ImageFormatError(description: "\(name): \(needsGIMP)")
        }
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("openquad-xcf-\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let out = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".tif")
        let log = folder.appendingPathComponent("gimp.log")
        files.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = gimp
        process.arguments = arguments()
        var env = environment
        env["OPENQUAD_XCF_IN"] = url.standardizedFileURL.path
        env["OPENQUAD_XCF_OUT"] = out.path
        process.environment = env
        process.standardOutput = logHandle
        process.standardError = logHandle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            throw ImageFormatError(description: "\(name): could not run GIMP (\(error.localizedDescription))")
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ImageFormatError(description: "\(name): GIMP took too long to open it")
        }
        guard files.fileExists(atPath: out.path) else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let detail = lines.last.map { " (\($0))" } ?? ""
            throw ImageFormatError(description: "\(name): GIMP 3 could not open it\(detail)")
        }
        return try body(out)
    }
}
