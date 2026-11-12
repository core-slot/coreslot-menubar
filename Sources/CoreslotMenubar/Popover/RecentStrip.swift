import SwiftUI

/// The last 30 minutes as run bars, hatched while waiting and solid while running, and the
/// forecast zone to the right of "now" with dashed outlines where coreslot gives a number.
struct RecentStrip: View {
    let model: StripModel
    private static let rowHeight: CGFloat = 4
    private static let rowGap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last 30 minutes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("forecast").font(.caption2).foregroundStyle(.tertiary)
            }
            Canvas { context, size in draw(&context, size) }
                .frame(height: max(12, CGFloat(model.bars.count) * (Self.rowHeight + Self.rowGap) + 2))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width
        let zone = CGRect(x: w * StripModel.nowX, y: 0, width: w * (1 - StripModel.nowX), height: size.height)
        context.fill(Path(zone), with: .color(.primary.opacity(0.04)))
        let y = { (row: Int) in 1 + CGFloat(row) * (Self.rowHeight + Self.rowGap) }
        for (row, bar) in model.bars.enumerated() {
            let color = Palette.label(bar.color)
            let runFrom = bar.runFrom ?? bar.to
            Palette.hatch(&context, CGRect(x: w * bar.waitFrom, y: y(row), width: w * max(0, runFrom - bar.waitFrom), height: Self.rowHeight), color)
            if bar.runFrom != nil {
                // A run of a second still shows.
                let rect = CGRect(x: w * runFrom, y: y(row), width: max(1.5, w * (bar.to - runFrom)), height: Self.rowHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
        let dashed = StrokeStyle(lineWidth: 1, dash: [2, 2])
        for f in model.forecasts {
            let top = f.row.map(y) ?? 1
            let color = Palette.label(f.color)
            if f.to > f.from {
                let rect = CGRect(x: w * f.from, y: top, width: w * (f.to - f.from), height: Self.rowHeight)
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1), with: .color(color), style: dashed)
            } else {
                var tick = Path()
                tick.move(to: CGPoint(x: w * f.from, y: top - 1))
                tick.addLine(to: CGPoint(x: w * f.from, y: top + Self.rowHeight + 1))
                context.stroke(tick, with: .color(color), style: dashed)
            }
        }
        var now = Path()
        now.move(to: CGPoint(x: w * StripModel.nowX, y: 0))
        now.addLine(to: CGPoint(x: w * StripModel.nowX, y: size.height))
        context.stroke(now, with: .color(.secondary), lineWidth: 1)
    }
}
