// A tab's walkthroughs, in a panel beside the tab: what the tab is for, a choice of
// walkthroughs and the chosen one's steps, to follow while you work. Opened with Walkthroughs
// in the toolbar; it shows the walkthroughs of whichever tab is in front.

import SwiftUI

struct TabWalkthroughsView: View {
    let tab: AppTab
    /// The walkthrough shown, by tab.
    @Binding var selection: [AppTab: Int]

    private var page: GuideView.Page { GuideView.page(for: tab) }

    private var shown: Int {
        min(max(selection[tab] ?? 0, 0), page.walkthroughs.count - 1)
    }

    var body: some View {
        let walkthroughs = page.walkthroughs
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(tab.title) Walkthroughs", systemImage: tab.symbol)
                    .font(.headline)
                Text(page.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Walkthrough", selection: Binding(get: { shown }, set: { selection[tab] = $0 })) {
                    ForEach(walkthroughs.indices, id: \.self) { i in Text(walkthroughs[i].title).tag(i) }
                }
                .labelsHidden()
            }
            .padding(14)
            Divider()
            ScrollView {
                WalkthroughSteps(walkthrough: walkthroughs[shown])
                    .padding(14)
            }
            .id("\(tab.rawValue)-\(shown)")  // each walkthrough starts at its top
            Divider()
            HStack {
                Button { selection[tab] = shown - 1 } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(shown == 0)
                    .help("The previous walkthrough")
                Spacer()
                Text("\(shown + 1) of \(walkthroughs.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { selection[tab] = shown + 1 } label: { Label("Next", systemImage: "chevron.right") }
                    .disabled(shown == walkthroughs.count - 1)
                    .help("The next walkthrough")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.title) walkthroughs")
    }
}
