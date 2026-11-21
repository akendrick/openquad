// The calibration wizards: printer calibration (print a comparison page, scan, measure,
// improve) and negative process calibration (print a chart page on film, contact print,
// scan, read, refine). Thin views over OpenQuadCore's CalibrationRun and ProcessRun;
// every step that uses paper, film or the scanner asks first, and slow steps run off
// the main thread.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared by both wizards: the log, the busy flag, scanners and running a step.
@MainActor
@Observable
public class WizardModel: Identifiable {
    public var log: [String] = []
    public var busy = false
    public var error: String?
    public var scannerHost: String
    public var scanners: [(name: String, host: String)] = []
    let find: @Sendable () -> [(String, String)]

    init(scannerHost: String, find: @escaping @Sendable () -> [(String, String)]) {
        self.scannerHost = scannerHost
        self.find = find
    }

    func say(_ line: String) { log.append(line) }

    /// Run `work` off the main thread, then `done` with its result (errors are shown).
    func step<T: Sendable>(_ name: String, _ work: @escaping @Sendable () throws -> T, done: @escaping (T) -> Void) {
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            busy = false
            switch result {
            case .success(let value): done(value)
            case .failure(let failure): error = "\(name.capitalized) failed: \(failure)"
            }
        }
    }

    public func findScanners() {
        say("Looking for scanners…")
        let find = self.find
        step("find", { find().map { (name: $0.0, host: $0.1) } }) { found in
            self.scanners = found
            if self.scannerHost.isEmpty, let first = found.first { self.scannerHost = first.host }
            self.say("Found \(found.count) scanner(s).")
        }
    }

    static func timestamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmm"
        return format.string(from: Date())
    }
}

/// Print an image through the print panel at its real size; true if it was printed.
@MainActor
func printWithPanel(_ request: (RGBImage, Double, Double, String, String)) -> Bool {
    guard let operation = NativePrint.operation(for: request.0, widthInches: request.1, heightInches: request.2,
                                                paper: request.3, title: request.4) else { return false }
    return operation.run()
}

@MainActor
func confirm(_ title: String, _ question: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = question
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
