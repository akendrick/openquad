// Scanning over eSCL (AirScan) with fixed settings, and finding scanners on the network.
// Mirrors openquad/escl.py. Every scan uses the same settings (RGB, sRGB, lowest
// compression, no automatic adjustments), so measurements from different days compare.

import Foundation

public struct ESCLError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public struct ScanSettings: Sendable, Equatable {
    public static let intents = ["Photo", "Document", "TextAndGraphic", "Preview"]
    public static let resolutions = [75, 100, 150, 200, 300, 600, 1200]
    /// 8.5 x 11 in, in 1/300 in units.
    public static let letter300ths = (2550, 3300)

    public let dpi: Int
    public let width: Int
    public let height: Int
    /// Document is the default for measuring: on the Canon MG3600, Photo auto-crops to
    /// one detected "photo" and alters its colour and levels.
    public let intent: String

    public init(dpi: Int = 300, width: Int = letter300ths.0, height: Int = letter300ths.1, intent: String = "Document") throws {
        guard Self.resolutions.contains(dpi) else { throw ESCLError(description: "unsupported scan resolution \(dpi)") }
        guard Self.intents.contains(intent) else {
            throw ESCLError(description: "intent must be one of ('Photo', 'Document', 'TextAndGraphic', 'Preview'), got \(pyRepr(intent))")
        }
        self.dpi = dpi
        self.width = width
        self.height = height
        self.intent = intent
    }

    public func xml() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
        xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.5</pwg:Version>
          <scan:Intent>\(intent)</scan:Intent>
          <pwg:ScanRegions>
            <pwg:ScanRegion>
              <pwg:Height>\(height)</pwg:Height>
              <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
              <pwg:Width>\(width)</pwg:Width>
              <pwg:XOffset>0</pwg:XOffset>
              <pwg:YOffset>0</pwg:YOffset>
            </pwg:ScanRegion>
          </pwg:ScanRegions>
          <pwg:InputSource>Platen</pwg:InputSource>
          <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
          <scan:XResolution>\(dpi)</scan:XResolution>
          <scan:YResolution>\(dpi)</scan:YResolution>
          <scan:ColorMode>RGB24</scan:ColorMode>
          <scan:ColorSpace>sRGB</scan:ColorSpace>
          <scan:CompressionFactor>0</scan:CompressionFactor>
        </scan:ScanSettings>

        """.utf8)
    }
}

public enum ESCL {
    /// (method, url, body) -> (status, Location header or "", body).
    public typealias Fetch = (String, String, Data?) throws -> (Int, String, Data)
    /// (command, seconds) -> what it printed.
    public typealias Browse = ([String], Double) -> String

    static let busyRetries = 10

    /// The path of a URL reference, as Python's urlsplit(...).path: what follows the host, if any.
    static func path(of reference: String) -> String {
        let cut = reference.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        guard let scheme = cut.range(of: "://") else { return cut }
        let rest = cut[scheme.upperBound...]
        return rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
    }

    /// RFC 3986 reference resolution, as Python's urljoin.
    static func join(_ base: String, _ reference: String) -> String {
        URL(string: reference, relativeTo: URL(string: base))?.absoluteURL.absoluteString ?? reference
    }

    /// Scan the platen and return the JPEG.
    public static func scan(host: String, settings: ScanSettings? = nil, fetch: Fetch = httpFetch,
                            sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> Data {
        let settings = try settings ?? ScanSettings()
        let base = host.hasPrefix("http") ? host : "http://\(host)"
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let jobsURL = join(trimmed + "/", "eSCL/ScanJobs")

        var (status, location, body) = (0, "", Data())
        for _ in 0..<busyRetries {
            (status, location, body) = try fetch("POST", jobsURL, settings.xml())
            if status != 503 { break }  // 503 = busy (e.g. warming up)
            sleep(2.0)
        }
        if status == 503 {
            throw ESCLError(description: "the scanner is busy: a scan job is still open on it (perhaps an earlier scan that "
                            + "didn't finish). Wait a minute and try again, or turn the printer off and on.")
        }
        guard status == 201, !location.isEmpty else {
            throw ESCLError(description: "scanner refused the job (HTTP \(status)): \(pyRepr(Array(body.prefix(200))))")
        }
        // Keep talking to the scanner the way we reached it: some (Epson) answer with an https://
        // job address even when asked over http, so use only the job's path.
        var job = path(of: location)
        while job.hasSuffix("/") { job.removeLast() }
        let jobURL = join(jobsURL, job)
        var image = Data()
        defer {
            // Close the job, or the scanner keeps it open and refuses the next one (503).
            _ = try? fetch("DELETE", jobURL, nil)
        }
        for _ in 0..<busyRetries {
            (status, _, image) = try fetch("GET", jobURL + "/NextDocument", nil)
            if status != 503 { break }
            sleep(2.0)
        }
        guard status == 200, image.starts(with: [0xff, 0xd8]) else {
            throw ESCLError(description: "no image from the scanner (HTTP \(status))")
        }
        return image
    }

    /// One HTTP request, waiting for the answer (scans can take a minute or two).
    public static func httpFetch(_ method: String, _ url: String, _ body: Data?) throws -> (Int, String, Data) {
        guard let target = URL(string: url) else { throw ESCLError(description: "can't reach the scanner at \(url): bad URL") }
        var request = URLRequest(url: target, timeoutInterval: 120)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        }
        final class Box: @unchecked Sendable { var result: Result<(Int, String, Data), Error>? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let response = response as? HTTPURLResponse {
                box.result = .success((response.statusCode, response.value(forHTTPHeaderField: "Location") ?? "", data ?? Data()))
            } else {
                var reason = error?.localizedDescription ?? "no response"
                while reason.hasSuffix(".") { reason.removeLast() }
                let blocked: [URLError.Code] = [.notConnectedToInternet, .timedOut, .cannotConnectToHost, .networkConnectionLost]
                if let code = (error as? URLError)?.code, blocked.contains(code) {
                    reason += ". If the scanner is on and other devices can reach it, macOS may be blocking OpenQuad from your "
                        + "local network: turn OpenQuad on in System Settings ▸ Privacy & Security ▸ Local Network."
                }
                box.result = .failure(ESCLError(description: "can't reach the scanner at \(url): \(reason)"))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result!.get()
    }

    // MARK: finding scanners on the network

    /// (name, host:port) from `avahi-browse -rpt _uscan._tcp` output.
    public static func parseAvahi(_ text: String) -> [(String, String)] {
        text.splitLines().compactMap { line in
            let fields = line.components(separatedBy: ";")
            guard fields.count >= 9, fields[0] == "=" else { return nil }
            return (fields[3].replacingOccurrences(of: "\\032", with: " "), "\(fields[6]):\(fields[8])")
        }
    }

    /// Instance names from `dns-sd -B _uscan._tcp` output.
    public static func parseDNSSDBrowse(_ text: String) -> [String] {
        text.splitLines().compactMap { line in
            let parts = splitWhitespace(line, maxSplits: 6)
            guard parts.count == 7, parts[1] == "Add", parts[5] == "_uscan._tcp." else { return nil }
            return parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// host:port from `dns-sd -L NAME _uscan._tcp` output.
    public static func parseDNSSDResolve(_ text: String) -> String? {
        for line in text.splitLines() {
            guard let range = line.range(of: "can be reached at") else { continue }
            let target = splitWhitespace(String(line[range.upperBound...]), maxSplits: -1).first ?? ""
            guard let colon = target.lastIndex(of: ":") else { return target }
            var host = String(target[..<colon])
            let port = String(target[target.index(after: colon)...])
            guard !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) else { return target }
            while host.hasSuffix(".") { host.removeLast() }
            return "\(host):\(port)"
        }
        return nil
    }

    /// Python str.split(None, maxsplit): runs of whitespace separate, leading and
    /// trailing whitespace ignored; the last part keeps its inner whitespace.
    static func splitWhitespace(_ s: String, maxSplits: Int) -> [String] {
        var parts: [String] = []
        var rest = Substring(s)
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty { break }
            if maxSplits >= 0 && parts.count == maxSplits {
                parts.append(String(rest))
                break
            }
            let end = rest.firstIndex { $0.isWhitespace } ?? rest.endIndex
            parts.append(String(rest[..<end]))
            rest = rest[end...]
        }
        return parts
    }

    /// Run a browsing command for `seconds` (they never exit on their own) and return its output.
    public static func runFor(_ command: [String], _ seconds: Double) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// eSCL scanners on the network: [(name, "host:port")], through avahi or dns-sd.
    public static func discover(browse: Browse = runFor, seconds: Double = 3.0, hasAvahi: Bool? = nil) -> [(String, String)] {
        let avahi = hasAvahi ?? ["/usr/bin/avahi-browse", "/usr/local/bin/avahi-browse"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        if avahi { return parseAvahi(browse(["avahi-browse", "-rpt", "_uscan._tcp"], seconds)) }
        var seen = Set<String>(), found: [(String, String)] = []
        for name in parseDNSSDBrowse(browse(["dns-sd", "-B", "_uscan._tcp"], seconds)) where seen.insert(name).inserted {
            if let host = parseDNSSDResolve(browse(["dns-sd", "-L", name, "_uscan._tcp"], seconds)) { found.append((name, host)) }
        }
        return found
    }
}
