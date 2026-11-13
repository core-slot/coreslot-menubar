import CoreslotKit
import SwiftUI

extension EnvironmentValues {
    /// Shows every row's hover actions at once, for looking at the popover without a pointer.
    @Entry var revealsRowActions = false
}

/// The popover: header, memory, running, waiting, the last 30 minutes, footer.
struct PopoverView: View {
    let store: Store
    let openTimeline: () -> Void

    var body: some View {
        let model = store.popover
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(model: model, openTimeline: openTimeline)
            switch model.body {
            case .reading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
            case .unavailable(let state, let fix):
                Divider()
                UnavailableView(state: state, fix: fix)
            case .noticeOnly:
                EmptyView()
            case .live(let live):
                Divider()
                MemorySection(model: live.memory)
                Divider()
                ListsSection(store: store, live: live)
                Divider()
                RecentStrip(model: live.strip)
                Divider()
                FooterView(totals: live.totals, openTimeline: openTimeline)
            }
        }
        .frame(width: 400)
    }
}

private struct UnavailableView: View {
    let state: String
    let fix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(state, systemImage: "exclamationmark.triangle").font(.headline)
            Text(fix).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}
