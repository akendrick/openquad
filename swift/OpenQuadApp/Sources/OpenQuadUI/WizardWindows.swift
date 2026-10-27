// The wizards open in ordinary windows (movable, resizable, alongside the print window)
// rather than sheets, and share a layout: a header, the work, and a log drawer that can
// be shown or hidden at the side.

import AppKit
import SwiftUI

@MainActor
public enum WizardWindows {
    static var windows: [String: NSWindow] = [:]

    /// Show the window `id` (bringing it forward if it's already open). `content` gets a
    /// closure that closes the window.
    public static func show<Content: View>(_ id: String, title: String, size: CGSize, minSize: CGSize,
                                           @ViewBuilder content: (@escaping () -> Void) -> Content) {
        if let window = windows[id], window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let close: () -> Void = { [weak window] in window?.close() }
        let host = NSHostingController(rootView: content(close))
        host.sizingOptions = []  // the window, not the content, decides the size
        window.contentViewController = host
        window.title = title
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OpenQuad.\(id)")  // remembers where you put it
        if window.frame.origin == .zero { window.center() }
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// A wizard's page: title, the work, and the log in a drawer at the side.
struct WizardScaffold<Header: View, Content: View>: View {
    let title: String
    let log: [String]
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @AppStorage("wizardLogShown") private var logShown = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title2.bold())
                    Spacer()
                    header()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { logShown.toggle() }
                    } label: {
                        Label(logShown ? "Hide Log" : "Show Log", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the log of what this wizard did")
                }
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if logShown {
                Divider()
                LogDrawer(lines: log)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The log, readable: one entry per line, newest at the bottom, scrolled into view.
struct LogDrawer: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Log").font(.headline).padding([.horizontal, .top], 14).padding(.bottom, 8)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { n, line in
                            Text(line)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(n)
                        }
                        if lines.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                    }
                    .padding(14)
                }
                .onChange(of: lines.count) { _, count in
                    if count > 0 { withAnimation { reader.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
