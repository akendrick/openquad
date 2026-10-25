// OpenQuad for macOS.
//
//     OpenQuad                          the app
//     OpenQuad --snapshot out.png [--photo PHOTO] [--negative]
//                                       draw the window to a PNG and quit (for checks)

import AppKit
import OpenQuadUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // also when run straight from `swift run`
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        Snapshot.takeIfAsked()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OpenQuadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = Snapshot.model()

    var body: some Scene {
        Window("OpenQuad", id: "print") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
        let model = AppModel(settingsURL: settings)
        if let photo = value("--photo") { model.openPhoto(URL(fileURLWithPath: photo)) }
        if arguments.contains("--negative") { model.setMode(.negative) }
        return model
    }

    static func takeIfAsked() {
        guard let output = value("--snapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
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
