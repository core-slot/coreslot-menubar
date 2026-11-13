import CoreslotKit
import SwiftUI

/// Running rows, then waiting rows; past four and five the lists scroll and the rest stays put.
struct ListsSection: View {
    let store: Store
    let live: PopoverModel.Live
    /// Closes the popover: a confirmation is a standard alert outside it.
    @Environment(\.dismiss) private var dismiss
    private static let runningHeight: CGFloat = 62
    private static let waitingHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if live.running.isEmpty && live.waiting.isEmpty {
                Text("Nothing running").foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 12)
            }
            if !live.running.isEmpty {
                SectionTitle(text: "Running", count: live.running.count)
                Rows(items: live.running, visible: 4, height: Self.runningHeight) { row in
                    RunningRowView(row: row) { dismiss(); store.askToStop(row.hold) }
                }
            }
            if !live.waiting.isEmpty {
                if !live.running.isEmpty { Divider() }
                SectionTitle(text: "Waiting", count: live.waiting.count)
                Rows(items: live.waiting, visible: 5, height: Self.waitingHeight) { row in
                    WaitingRowView(row: row) { dismiss(); store.askToCancel(row.ticket) }
                }
                if let note = live.recordNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.bottom, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.subheadline.weight(.semibold))
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct Rows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let visible: Int
    let height: CGFloat
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        let list = VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider().padding(.leading, 14) }
                row(item).frame(height: height)
            }
        }
        if items.count > visible {
            // Half a row more than fits says that the list goes on.
            ScrollView { list }.frame(height: (CGFloat(visible) + 0.5) * height)
        } else {
            list
        }
    }
}

private struct RowAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .controlSize(.small)
    }
}

struct RunningRowView: View {
    let row: RunningRow
    let stop: () -> Void
    @State private var hovering = false
    @Environment(\.revealsRowActions) private var reveal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Palette.label(row.color)).frame(width: 7, height: 7)
                Text(row.label).lineLimit(1).truncationMode(.middle)
                if row.hold.container == true {
                    Text("container").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 0.5))
                }
                Spacer(minLength: 6)
                if hovering || reveal {
                    if row.stoppable {
                        RowAction(title: "Stop", symbol: "stop.circle", action: stop)
                    } else {
                        Text(row.quiet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(Formatting.timeLeft(row.hold.leftS)).font(.callout).monospacedDigit().lineLimit(1).layoutPriority(1)
            }
            if let progress = row.progress {
                ProgressBar(fraction: progress, color: Palette.label(row.color)).frame(height: 3)
            }
            HStack(spacing: 8) {
                Text(row.figures).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Spacer(minLength: 6)
                Sparkline(values: row.spark, peak: row.peakIndex, color: Palette.label(row.color)).frame(width: 64, height: 14)
            }
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .rowAction("Stop", row.stoppable ? stop : nil)
    }
}

struct WaitingRowView: View {
    let row: WaitingRow
    let cancel: () -> Void
    @State private var hovering = false
    @Environment(\.revealsRowActions) private var reveal

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().strokeBorder(Palette.label(row.color), lineWidth: 1.5).frame(width: 7, height: 7)
                Text(row.label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if row.cancelRequested {
                    Text("Cancel requested").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if hovering || reveal {
                    RowAction(title: "Cancel request", symbol: "xmark.circle", action: cancel)
                }
                if let trailing = row.trailing { Text(trailing).font(.callout).monospacedDigit().lineLimit(1).layoutPriority(1) }
            }
            HStack(spacing: 8) {
                Text(row.reason ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(row.waited).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .rowAction("Cancel request", row.cancelRequested ? nil : cancel)
    }
}

extension View {
    /// The row's action without a pointer too: in its context menu, and as the action of the row,
    /// one accessibility element. Nil where the row has none: no menu and no action.
    fileprivate func rowAction(_ title: String, _ action: (() -> Void)?) -> some View {
        let button = action.map { Button(title, action: $0) }
        return accessibilityElement(children: .combine).accessibilityActions { button }.contextMenu { button }
    }
}

/// The footprint over the hold's recent past, with its peak marked.
private struct Sparkline: View {
    let values: [Double]
    let peak: Int?
    let color: Color

    var body: some View {
        Sketch { context, size in
            guard values.count >= 2 else { return }
            let step = size.width / CGFloat(values.count - 1)
            let point = { (i: Int) in CGPoint(x: CGFloat(i) * step, y: size.height - 1 - CGFloat(values[i]) * (size.height - 2)) }
            var line = Path()
            line.move(to: point(0))
            for i in values.indices.dropFirst() { line.addLine(to: point(i)) }
            context.stroke(line, with: color, lineWidth: 1.2)
            if let peak {
                let p = point(peak)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: color)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Elapsed against the typical run time, thin, in the label's colour.
private struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(color).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Elapsed against its usual time")
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded())) percent")
    }
}
