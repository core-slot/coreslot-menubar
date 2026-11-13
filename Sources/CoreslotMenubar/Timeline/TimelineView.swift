import AppKit
import CoreslotKit
import SwiftUI

/// The timeline window: totals for the range, memory, why they wait, and one row per run, with
/// the forecast zone after now. Scrolling or dragging sideways goes back in time and pauses live.
struct TimelineView: View {
    let store: Store
    @State private var range: Series.Range
    /// Nil while live.
    @State private var end: Date?
    @State private var label: String?
    @State private var dragFrom: Date?

    /// The row labels' column; every chart starts after it, so all share one time axis.
    static let gutter: CGFloat = 132
    static let trailing: CGFloat = 16

    init(store: Store, range: Series.Range = .hour, end: Date? = nil) {
        self.store = store
        _range = State(initialValue: range)
        _end = State(initialValue: end)
    }

    var body: some View {
        let model = store.timeline(range: range, end: end, label: label)
        GeometryReader { g in
            Group {
                if let model {
                    content(model, width: g.size.width)
                } else {
                    unavailable
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 560)
        .toolbar { toolbar(model) }
        .navigationTitle("Timeline")
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: TimelineModel?) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Range", selection: $range) {
                ForEach(Series.Range.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItem {
            Picker("Label", selection: $label) {
                Text("All labels").tag(String?.none)
                ForEach(model?.labels ?? [], id: \.self) { Text(SafeText.display($0)).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            .help("Show the runs of one label")
        }
        ToolbarItem {
            if end == nil {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Live")
                }
                .accessibilityElement(children: .combine)
                .help("Following now; scroll sideways to go back")
            } else {
                Button("Back to now") { end = nil }
                    .help(model.map { "Paused at \(Self.minutes.string(from: Date(nanoseconds: $0.viewEndNS)))" } ?? "Paused")
            }
        }
    }

    private func content(_ m: TimelineModel, width: CGFloat) -> some View {
        let plot = max(1, width - Self.gutter - Self.trailing)
        return VStack(alignment: .leading, spacing: 0) {
            TotalsRow(totals: m.totals)
            Divider()
            if let memory = m.memory, let strip = m.strip {
                TimelineMemory(model: m, memory: memory)
                Divider()
                TimelineStrip(model: m, strip: strip)
            } else if let empty = m.empty {
                RecordOff(looksOff: empty.looksOff, configFile: empty.configFile)
            }
            Divider()
            TimelineRuns(model: m)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { g in
                let from = dragFrom ?? end ?? store.now
                dragFrom = from
                shift(from, by: g.translation.width, plot: plot)
            }
            .onEnded { _ in dragFrom = nil })
        .background(ScrollWheel { dx in shift(end ?? store.now, by: dx, plot: plot) })
    }

    /// Moves the end of the range by `dx` points of the plot, back for a positive `dx`; at now,
    /// live again.
    private func shift(_ from: Date, by dx: CGFloat, plot: CGFloat) {
        let now = store.now
        let to = from.addingTimeInterval(-Double(dx) / Double(plot) * Double(range.spanS))
        let earliest = now.addingTimeInterval(-Double(RecordReader.keepS - range.spanS))
        end = to >= now.addingTimeInterval(-1) ? nil : max(earliest, to)
    }

    @ViewBuilder private var unavailable: some View {
        let p = store.popover
        VStack(alignment: .leading, spacing: 6) {
            switch p.body {
            case .unavailable(let state, let fix):
                Label(state, systemImage: "exclamationmark.triangle").font(.headline)
                Text(fix).foregroundStyle(.secondary)
            case .reading, .live:
                ProgressView().controlSize(.small)
            case .noticeOnly:
                EmptyView()
            }
            ForEach(p.notices, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
        }
        .padding(20)
    }

    static let minutes: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

private struct TotalsRow: View {
    let totals: [(title: String, value: String)]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            ForEach(totals, id: \.title) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.caption).foregroundStyle(.secondary)
                    Text(t.value).font(.title3.weight(.medium)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The record looks off, or holds nothing in the range: one calm state for the memory chart, the
/// reasons and the processes.
private struct RecordOff: View {
    let looksOff: Bool
    let configFile: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(looksOff ? "coreslot's local record looks off" : "Nothing was recorded in this range").font(.headline)
            Text((looksOff ? "Memory over time, why commands waited and the largest processes come from it."
                  : "coreslot records memory and why commands wait only while a command runs, and only with its local record on.")
                + " These two lines in \(SafeText.display(configFile)) turn it on:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("[telemetry]\nenabled = true")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if looksOff {
                Text("Until then the runs below come from the run log and from what this app has seen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// Sideways scrolling over the window, which SwiftUI does not report outside a scroll view.
private struct ScrollWheel: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> Monitor {
        let v = Monitor()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ v: Monitor, context: Context) { v.onScroll = onScroll }

    final class Monitor: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY, at = event.locationInWindow
                let number = event.window?.windowNumber
                let taken = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, number == window.windowNumber, abs(dx) > abs(dy),
                          self.bounds.contains(self.convert(at, from: nil))
                    else { return false }
                    self.onScroll?(dx)
                    return true
                }
                return taken ? nil : event
            }
        }
    }
}
