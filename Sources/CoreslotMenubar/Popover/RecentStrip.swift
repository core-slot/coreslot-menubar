import SwiftUI

/// The last 30 minutes as run bars, hatched while waiting and solid while running, and the
/// forecast zone to the right of "now" with dashed outlines where coreslot gives a number.
struct RecentStrip: View {
    let model: RunStrip
    private static let rowHeight: CGFloat = 4
    private static let rowGap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last 30 minutes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("forecast").font(.caption2).foregroundStyle(.tertiary)
            }
            Sketch { context, size in draw(&context, size) }
                .frame(height: max(12, CGFloat(model.rows.count) * (Self.rowHeight + Self.rowGap) + 2))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func draw(_ context: inout Sketcher, _ size: CGSize) {
        nowZone(&context, size, at: model.x(model.nowNS))
        for (i, row) in model.rows.enumerated() {
            drawRun(&context, row, nowNS: model.nowNS, x: model.x, width: size.width, top: 1 + CGFloat(i) * (Self.rowHeight + Self.rowGap), height: Self.rowHeight)
        }
        nowLine(&context, size, at: model.x(model.nowNS))
    }
}
