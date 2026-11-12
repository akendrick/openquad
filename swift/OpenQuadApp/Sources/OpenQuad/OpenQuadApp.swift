// OpenQuad for macOS.
//
//     OpenQuad                          the app
//     OpenQuad --snapshot out.png [--tab print|negative|contact-sheet|printer-calibration|process-calibration]
//                                       [--photo PHOTO] [--negative] [--printer CUPS_QUEUE] [--max-size WxH] [--notice TEXT]
//                                       [--outline INCHES] [--units in|mm] [--setups FOLDER] [--setup NAME]
//                                       [--separations N] [--layer K] [--overlap STEPS] [--step-test] [--coats-chart]
//                                       [--show-coats]
//     OpenQuad --snapshot out.png --wizard calibration|process|blocking|guide|contact-sheet [--scan SCAN] [--run RUN]
//                                       [--photos P1,P2,...] [--landscape] [--white] [--wedge] [--labels] [--crop]
//                                       (contact-sheet)
//                                       [--mixtures] (blocking: the ink-mixture chart)
//                                       [--page N] (guide: the page to show, 0 first)
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
        // Run from Xcode or `swift run` there is no app bundle, so no AppIcon.icns: use the same
        // icon from the package's resources (the bundled app gets it from its Info.plist).
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        Snapshot.takeIfAsked()
        ScanTest.runIfAsked()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Offer to keep the open photos for next time.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { (OpenQuadApp.root?.confirmQuit() ?? true) ? .terminateNow : .terminateCancel }
    }
}

@main
struct OpenQuadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var root = Snapshot.root()
    /// For the app delegate's quit question.
    @MainActor static var root: AppRoot?

    init() {
        // Options like "--negative --max-size 4x5" would otherwise leave "4x5" looking like a
        // file to open, and then the print window doesn't open at launch.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        Self.root = root
    }

    var body: some Scene {
        Window("OpenQuad (Beta)", id: "print") {
            Snapshot.content(root)
        }
        .defaultSize(width: 1100, height: 720)
        Settings {
            SettingsView(root: root)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Contact Sheet…") { root.show(.contactSheet) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(before: .toolbar) {
                ForEach(AppTab.allCases) { tab in
                    Button(tab.title) { root.show(tab) }
                        .keyboardShortcut(tab.shortcut, modifiers: .command)
                }
                Divider()
            }
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

    static func root() -> AppRoot {
        guard value("--snapshot") != nil else { return AppRoot() }
        // A throwaway settings file, so snapshots never change the user's settings.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-snapshot")
        try? FileManager.default.removeItem(at: folder)
        let negative = arguments.contains("--negative")
        let tab = value("--tab").flatMap(AppTab.init(rawValue:)) ?? (negative ? .negative : .print)
        // The real calibrations, so the snapshot shows what this Mac has.
        let root = AppRoot(settingsURL: folder.appendingPathComponent("settings.json"),
                           libraryFolder: AppSettings.dataDirectory().appendingPathComponent("calibrations"),
                           setupsFolder: value("--setups").map { URL(fileURLWithPath: $0) }
                               ?? AppSettings.dataDirectory().appendingPathComponent("setups"),
                           tab: tab, restoreWorkspace: false)
        root.askOnQuit = false
        let model = tab == .negative ? root.negativeModel : root.printModel
        if let units = value("--units").flatMap(LengthUnit.init(rawValue:)) { root.setUnits(units) }
        if let photo = value("--photo") { model.openPhoto(URL(fileURLWithPath: photo)) }
        if let printer = value("--printer") { model.setPrinter(printer) }
        if let name = value("--setup"), let setup = model.setups.first(where: { $0.name == name }) { model.applySetup(setup) }
        if let size = value("--max-size")?.lowercased().split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            model.setMaxSize((size[0], size[1]))
        }
        if let outline = value("--outline").flatMap(Double.init) {
            model.setOutlineSize(outline)
            model.setOutline(true)
        }
        if arguments.contains("--guide") { model.setGuide(true) }
        if arguments.contains("--registration") { model.setRegistration(true) }
        if let count = value("--separations").flatMap(Int.init) { model.setNegativeCount(count) }
        if let overlap = value("--overlap").flatMap(Double.init) { model.setSeparationOverlap(overlap) }
        if arguments.contains("--step-test") { model.openStepTest() }
        if arguments.contains("--coats-chart") { model.openCoatsChart() }
        if arguments.contains("--show-coats") { model.setShowCoats(true) }
        if let layer = value("--layer").flatMap(Int.init) { model.setLayer(layer - 1) }
        if arguments.contains("--sheet-size") {  // the test sheets' set size, and their marks
            root.show(.processCalibration)
            root.blocking?.sheetSize = (8, 10)
            root.process?.sheetSize = (8, 10)
            root.blocking?.guide = arguments.contains("--guide")
            root.blocking?.registration = arguments.contains("--registration")
            root.show(tab)
        }
        if let notice = value("--notice") { root.notice = notice }
        if tab == .contactSheet { fillSheet(root.contactSheet) }
        return root
    }

    static func fillSheet(_ sheet: ContactSheetModel) {
        if arguments.contains("--landscape") { sheet.setLandscape(true) }
        sheet.update {
            $0.background = arguments.contains("--white") ? .white : .black
            $0.wedge = arguments.contains("--wedge")
            $0.labels = arguments.contains("--labels")
            $0.crop = arguments.contains("--crop")
        }
        sheet.add((value("--photos") ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) })
    }

    /// The print window, or (for a snapshot) one of the wizards, filled in from a scan.
    static func content(_ root: AppRoot) -> AnyView {
        wizard ?? AnyView(RootView(root: root, guideOnLaunch: value("--snapshot") == nil))
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
            if let run = value("--run") {
                wizard.resume(URL(fileURLWithPath: run))  // a real run, as it was left
            } else {
                wizard.start()
                wizard.printed("print panel")
                if let scan { wizard.scanAndMeasure(file: scan) }
            }
            return AnyView(CalibrationWizardView(model: wizard) { _ in })
        case "process":
            let wizard = ProcessWizardModel(folder: folder, scannerHost: "876298000000.local:80", find: { [] })
            wizard.start()
            wizard.printed("printed elsewhere")
            if let scan { wizard.scanAndRead(file: scan) }
            return AnyView(ProcessWizardView(model: wizard) { _ in })
        case "blocking":
            let test = BlockingTestModel(scannerHost: "876298000000.local:80", find: { [] })
            if arguments.contains("--mixtures") { test.chart = .mixtures }
            if let scan { test.read(file: scan) }
            return AnyView(BlockingTestView(model: test) { _ in })
        case "guide":
            return AnyView(GuideView(page: value("--page").flatMap(Int.init) ?? 0))
        case "contact-sheet":
            let sheet = ContactSheetModel(room: (7.5, 10), folder: folder)
            fillSheet(sheet)
            return AnyView(ContactSheetView(model: sheet) { _, _ in })
        default:
            return nil
        }
    }

    static func takeIfAsked() {
        guard let output = value("--snapshot") else { return }
        let wait = Double(value("--wait") ?? "") ?? (value("--wizard") == nil ? 2.5 : 8.0)  // a wizard reads its scan
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            // The frame view, so the toolbar (the tab bar) is in the picture too.
            guard let content = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let view = Optional(content.superview ?? content),
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                let windows = NSApp.windows.map { "\($0.title) visible=\($0.isVisible) frame=\($0.frame)" }
                FileHandle.standardError.write(Data("no window to snapshot; windows: \(windows)\n".utf8))
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
