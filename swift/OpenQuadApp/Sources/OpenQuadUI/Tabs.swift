// The window's five tabs: Print, Negative, Contact Sheet, Printer Calibration and
// Process Calibration. Each keeps its own work while you use the others (calibrate one
// printer, print on another, refine a process), and results are handed between them.

import AppKit
import OpenQuadCore
import SwiftUI

public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case print
    case negative
    case contactSheet = "contact-sheet"
    case printerCalibration = "printer-calibration"
    case processCalibration = "process-calibration"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .print: "Print"
        case .negative: "Negative"
        case .contactSheet: "Contact Sheet"
        case .printerCalibration: "Printer Calibration"
        case .processCalibration: "Process Calibration"
        }
    }

    public var symbol: String {
        switch self {
        case .print: "printer"
        case .negative: "film"
        case .contactSheet: "square.grid.3x3"
        case .printerCalibration: "slider.horizontal.3"
        case .processCalibration: "chart.line.uptrend.xyaxis"
        }
    }

    /// ⌘1 to ⌘5.
    public var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

/// What can be kept for next time: each tab's photo and the contact sheet.
public struct Workspace: Codable, Equatable, Sendable {
    public var printPhoto: String?
    public var negativePhoto: String?
    public var sheetPhotos: [String] = []
    public var sheetLandscape = false
    public var sheetBackground = "black"
    public var sheetCrop = false
    public var sheetWedge = false
    public var sheetLabels = false
    public var sheetGap = 0.15

    public var isEmpty: Bool { printPhoto == nil && negativePhoto == nil && sheetPhotos.isEmpty }
}

@MainActor
@Observable
public final class AppRoot {
    public var tab: AppTab {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
            arrived(at: tab)
        }
    }
    public let printModel: AppModel
    public let negativeModel: AppModel
    public let contactSheet: ContactSheetModel
    /// The calibration runs, made when their tab is first opened.
    public private(set) var calibration: CalibrationWizardModel?
    public private(set) var process: ProcessWizardModel?
    public private(set) var blocking: BlockingTestModel?
    /// Process Calibration's two steps: the blocking colour, then the curve.
    public enum ProcessStep: String, CaseIterable, Sendable {
        case blocking = "1. Blocking colour"
        case curve = "2. Process curve"
    }
    public var processStep = ProcessStep.blocking
    /// What a hand-off between tabs just changed, shown under the tab bar.
    public var notice: String?
    /// Ask on quit whether to keep the photos for next time (off for snapshots and tests).
    public var askOnQuit = true

    static let tabKey = "selectedTab"
    let workspaceURL: URL

    public init(settingsURL: URL = AppSettings.defaultURL(), libraryFolder: URL? = nil, setupsFolder: URL? = nil,
                tab: AppTab? = nil, restoreWorkspace: Bool = true) {
        printModel = AppModel(settingsURL: settingsURL, libraryFolder: libraryFolder, setupsFolder: setupsFolder, role: .print)
        negativeModel = AppModel(settingsURL: settingsURL, libraryFolder: libraryFolder, setupsFolder: setupsFolder,
                                 role: .negative)
        contactSheet = ContactSheetModel(room: printModel.printableRoom, units: printModel.units,
                                         folder: printModel.contactSheetFolder)
        workspaceURL = settingsURL.deletingLastPathComponent().appendingPathComponent("workspace.json")
        self.tab = tab ?? UserDefaults.standard.string(forKey: Self.tabKey).flatMap(AppTab.init(rawValue:)) ?? .print
        if restoreWorkspace { restore() }
        arrived(at: self.tab)
        // The printer calibration can open before the printers are looked up.
        printModel.printersLoaded = { [weak self] in self?.calibration?.offerPrinters($0) }
    }

    public func show(_ tab: AppTab) { self.tab = tab }

    /// Lengths in inches or millimetres, everywhere.
    public func setUnits(_ units: LengthUnit) {
        printModel.setUnits(units)
        negativeModel.followUnits()
        contactSheet.units = units
        blocking?.units = units
        process?.units = units
    }

    /// Bring a tab up to date with the others when it is shown.
    func arrived(at tab: AppTab) {
        switch tab {
        case .print: printModel.followUnits()
        case .negative: negativeModel.followUnits()
        case .contactSheet:
            contactSheet.units = printModel.units
            contactSheet.setRooms(print: printModel.printableRoom, negative: negativeModel.printableRoom)
        case .printerCalibration:
            if calibration == nil { calibration = printModel.calibrationWizard() }
        case .processCalibration:
            if blocking == nil { blocking = negativeModel.blockingTest() }
            if process == nil { process = negativeModel.processWizard() }
        }
    }

    /// Start a fresh printer calibration (for the Print tab's printer and paper).
    public func newCalibration() { calibration = printModel.calibrationWizard() }

    /// Start a fresh process calibration and blocking test.
    public func newProcess() {
        blocking = negativeModel.blockingTest()
        process = negativeModel.processWizard()
        processStep = .blocking
    }

    // MARK: hand-offs between tabs

    /// A finished printer calibration: used in the Print tab when it prints on that printer
    /// (negatives are shaped by their process curve instead).
    public func useCalibration(_ path: URL, scannerHost: String) {
        let entry = CalibrationLibrary.entry(path)
        let label = entry?.label ?? path.lastPathComponent
        if let printer = entry?.printer, let current = printModel.session.printer, current != printer {
            printModel.refreshLibrary()
            notice = "Saved \(label). The Print tab prints on \(LibraryEntry.printerName(current)); "
                + "choose \(LibraryEntry.printerName(printer)) there to use it."
        } else {
            printModel.finishCalibration(path, scannerHost: scannerHost)
            notice = "The Print tab now uses \(label)."
        }
        tab = .print
    }

    /// The blocking test's best colour: used for negatives, and the colour the process
    /// curve is calibrated in.
    public func useBlockingColour(_ colour: String, scannerHost: String) {
        negativeModel.useBlockingColour(colour, scannerHost: scannerHost)
        if let process {
            if !process.started {
                process.colours = [colour]
                process.useColour = colour
            } else if process.run?.colours.contains(colour) == true {
                process.useColour = colour
            }  // a run already started in other colours keeps them (New Run… starts one in this colour)
        }
        processStep = .curve
        notice = "Negatives now print in \(colour). Next: calibrate the process curve in \(colour)."
    }

    /// A finished process curve: used in the Negative tab, with an offer to save a setup.
    public func useProcess(_ path: URL, scannerHost: String) {
        negativeModel.finishProcess(path, scannerHost: scannerHost)
        negativeModel.setupOffer = "Using the new curve \(path.lastPathComponent). Save it as a setup to switch back to it later?"
        notice = "The Negative tab now uses \(path.lastPathComponent)."
        tab = .negative
    }

    /// A made contact sheet, opened in the Print or Negative tab.
    public func useContactSheet(_ url: URL, for role: TabRole) {
        (role == .negative ? negativeModel : printModel).useContactSheet(url)
        notice = "The contact sheet is open in the \(role == .negative ? "Negative" : "Print") tab."
        tab = role == .negative ? .negative : .print
    }

    // MARK: keeping work for next time

    /// What would be kept now.
    public var workspace: Workspace {
        var kept = Workspace()
        kept.printPhoto = printModel.session.source?.path
        kept.negativePhoto = negativeModel.session.source?.path
        kept.sheetPhotos = contactSheet.entries.map(\.url.path)
        kept.sheetLandscape = contactSheet.landscape
        kept.sheetBackground = contactSheet.layout.background.rawValue
        kept.sheetCrop = contactSheet.layout.crop
        kept.sheetWedge = contactSheet.layout.wedge
        kept.sheetLabels = contactSheet.layout.labels
        kept.sheetGap = contactSheet.layout.gap
        return kept
    }

    public func keepWorkspace() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(workspace).write(to: workspaceURL, options: .atomic)
    }

    public func forgetWorkspace() { try? FileManager.default.removeItem(at: workspaceURL) }

    /// Reopen kept work (once: it is asked about again at the next quit).
    func restore() {
        guard let data = try? Data(contentsOf: workspaceURL),
              let kept = try? JSONDecoder().decode(Workspace.self, from: data) else { return }
        forgetWorkspace()
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        if let path = kept.printPhoto, exists(path) { printModel.openPhoto(URL(fileURLWithPath: path)) }
        if let path = kept.negativePhoto, exists(path) { negativeModel.openPhoto(URL(fileURLWithPath: path)) }
        contactSheet.setLandscape(kept.sheetLandscape)
        contactSheet.update {
            $0.background = SheetLayout.Background(rawValue: kept.sheetBackground) ?? .black
            $0.crop = kept.sheetCrop
            $0.wedge = kept.sheetWedge
            $0.labels = kept.sheetLabels
            $0.gap = min(max(kept.sheetGap, 0), 1)
        }
        contactSheet.add(kept.sheetPhotos.filter(exists).map { URL(fileURLWithPath: $0) })
    }

    /// On quit: if there is work open, ask whether to keep it. False cancels the quit.
    public func confirmQuit() -> Bool {
        guard askOnQuit, !workspace.isEmpty else {
            forgetWorkspace()
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Keep your photos for next time?"
        alert.informativeText = "OpenQuad can reopen the photos in Print and Negative and the contact sheet's photos "
            + "the next time it starts, so you can carry on where you left off."
        alert.addButton(withTitle: "Keep for Next Time")
        alert.addButton(withTitle: "Start Fresh")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? keepWorkspace()
            return true
        case .alertSecondButtonReturn:
            forgetWorkspace()
            return true
        default:
            return false
        }
    }
}

/// The window: the tab bar in the toolbar and the chosen tab's page.
public struct RootView: View {
    @Bindable var root: AppRoot
    @State private var showGuide = false
    @AppStorage("guideSeen") private var guideSeen = 0
    let guideOnLaunch: Bool

    public init(root: AppRoot, guideOnLaunch: Bool = true) {
        self.root = root
        self.guideOnLaunch = guideOnLaunch
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let notice = root.notice {
                HStack {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text(notice).font(.callout)
                    Spacer()
                    Button { root.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.08))
                Divider()
            }
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .principal) { TabBar(selection: $root.tab) }
            ToolbarItem(placement: .primaryAction) {
                Button { showGuide = true } label: { Label("How to Use OpenQuad", systemImage: "questionmark.circle") }
                    .help("How to use OpenQuad")
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $showGuide) { GuideView { guideSeen = GuideView.version } }
        .onReceive(NotificationCenter.default.publisher(for: GuideView.showNotification)) { _ in showGuide = true }
        .onAppear {
            if guideOnLaunch && guideSeen < GuideView.version { showGuide = true }  // first launch: walk through the app
            root.printModel.loadPrinters()  // whichever tab opens first, the wizards get the printers too
        }
    }

    @ViewBuilder private var page: some View {
        switch root.tab {
        case .print:
            ContentView(model: root.printModel, goTo: root.show).id(AppTab.print)
        case .negative:
            ContentView(model: root.negativeModel, goTo: root.show).id(AppTab.negative)
        case .contactSheet:
            ContactSheetView(model: root.contactSheet) { url, role in root.useContactSheet(url, for: role) }
        case .printerCalibration:
            if let wizard = root.calibration {
                CalibrationWizardView(model: wizard) { root.useCalibration($0, scannerHost: wizard.scannerHost) }
                    .id(ObjectIdentifier(wizard))
                    .toolbar {
                        ToolbarItem { Button("New Calibration", action: root.newCalibration).help("Start again for the Print tab's printer and paper") }
                    }
            }
        case .processCalibration:
            VStack(spacing: 0) {
                Picker("Step", selection: $root.processStep) {
                    ForEach(AppRoot.ProcessStep.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .padding(10)
                Divider()
                switch root.processStep {
                case .blocking:
                    if let test = root.blocking {
                        BlockingTestView(model: test) { root.useBlockingColour($0, scannerHost: test.scannerHost) }
                            .id(ObjectIdentifier(test))
                    }
                case .curve:
                    if let wizard = root.process {
                        ProcessWizardView(model: wizard) { root.useProcess($0, scannerHost: wizard.scannerHost) }
                            .id(ObjectIdentifier(wizard))
                    }
                }
            }
            .toolbar {
                ToolbarItem { Button("New Process", action: root.newProcess).help("Start the blocking test and curve again") }
            }
        }
    }
}

/// Five labelled icons, the chosen one highlighted.
struct TabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppTab.allCases) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol).font(.system(size: 15))
                        Text(tab.title).font(.caption)
                    }
                    .frame(minWidth: 112)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                    .background(selection == tab ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("\(tab.title) (⌘\(AppTab.allCases.firstIndex(of: tab)! + 1))")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
    }
}
