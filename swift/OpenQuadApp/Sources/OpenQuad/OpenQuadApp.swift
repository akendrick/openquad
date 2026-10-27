// OpenQuad for macOS.
//
//     OpenQuad                          the app
//     OpenQuad --snapshot out.png [--photo PHOTO] [--negative] [--printer CUPS_QUEUE]
//     OpenQuad --snapshot out.png --wizard calibration|process|blocking|guide [--scan SCAN]
//                                       draw the window to a PNG and quit (for checks)
//     OpenQuad --scan-test HOST RESULT  scan once from the app (with its own network
//                                       permissions), write OK or the error to RESULT, quit

import AppKit
import OpenQuadCore
import OpenQuadUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // also when run straight from `swift run`
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        Snapshot.takeIfAsked()
        ScanTest.runIfAsked()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OpenQuadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = Snapshot.model()

    var body: some Scene {
        Window("OpenQuad (Beta)", id: "print") {
            Snapshot.content(model)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("How to Use OpenQuad") { NotificationCenter.default.post(name: GuideView.showNotification, object: nil) }
                    .keyboardShortcut("?")
            }
        }
    }
}

/// `--snapshot`: render the window to a PNG (with a photo, optionally as a negative).
@MainActor
enum Snapshot {
    static let arguments = CommandLine.arguments

    static func value(_ flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func model() -> AppModel {
        guard value("--snapshot") != nil else { return AppModel() }
        // A throwaway settings file, so snapshots never change the user's settings.
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-snapshot-settings.json")
        try? FileManager.default.removeItem(at: settings)
        // The real calibrations, so the snapshot shows what this Mac has.
        let model = AppModel(settingsURL: settings, libraryFolder: AppSettings.dataDirectory().appendingPathComponent("calibrations"))
        if let photo = value("--photo") { model.openPhoto(URL(fileURLWithPath: photo)) }
        if arguments.contains("--negative") { model.setMode(.negative) }
        if let printer = value("--printer") { model.setPrinter(printer) }
        return model
    }

    /// The print window, or (for a snapshot) one of the wizards, filled in from a scan.
    static func content(_ model: AppModel) -> AnyView {
        wizard ?? AnyView(ContentView(model: model, guideOnLaunch: value("--snapshot") == nil))
    }

    /// Built once: the scene's body is evaluated again on every change.
    static let wizard: AnyView? = makeWizard()

    static func makeWizard() -> AnyView? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-snapshot-runs")
        let scan = value("--scan").map { URL(fileURLWithPath: $0) }
        switch value("--wizard") {
        case "calibration":
            let wizard = CalibrationWizardModel(folder: folder, paper: "Letter", scannerHost: "876298000000.local:80",
                                                starting: nil, startingName: nil, printers: ["Canon_MG3600_series"],
                                                printer: "Canon_MG3600_series", find: { [] })
            wizard.start()
            wizard.printed("print panel")
            if let scan { wizard.scanAndMeasure(file: scan) }
            return AnyView(CalibrationWizardView(model: wizard) { _ in })
        case "process":
            let wizard = ProcessWizardModel(folder: folder, scannerHost: "876298000000.local:80", find: { [] })
            wizard.start()
            wizard.printed("printed elsewhere")
            if let scan { wizard.scanAndRead(file: scan) }
            return AnyView(ProcessWizardView(model: wizard) { _ in })
        case "blocking":
            let test = BlockingTestModel(scannerHost: "876298000000.local:80", find: { [] })
            if let scan { test.read(file: scan) }
            return AnyView(BlockingTestView(model: test) { _ in })
        case "guide":
            return AnyView(GuideView())
        default:
            return nil
        }
    }

    static func takeIfAsked() {
        guard let output = value("--snapshot") else { return }
        let wait = value("--wizard") == nil ? 2.5 : 8.0  // let a wizard finish reading its scan
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                FileHandle.standardError.write(Data("no window to snapshot\n".utf8))
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            exit(0)
        }
    }
}

/// `--scan-test HOST RESULT`: check the app itself can reach a scanner (macOS grants
/// local network access per app, so a test from Terminal proves nothing about the app).
enum ScanTest {
    static func runIfAsked() {
        let arguments = CommandLine.arguments
        guard let i = arguments.firstIndex(of: "--scan-test"), i + 2 < arguments.count else { return }
        let host = arguments[i + 1], result = URL(fileURLWithPath: arguments[i + 2])
        DispatchQueue.global().async {
            let text: String
            do {
                let image = try ESCL.scan(host: host)
                text = "OK \(image.count) bytes"
            } catch {
                text = "ERROR \(error)"
            }
            try? (text + "\n").write(to: result, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
