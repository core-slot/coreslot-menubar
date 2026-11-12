import SwiftUI

/// Label colours, categorical: a label keeps its index for as long as the app knows it.
enum Palette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .mint, .brown, .cyan, .yellow]

    static func label(_ index: Int) -> Color { colors[index % colors.count] }

    static func fill(_ kind: MemoryModel.Kind) -> Color {
        switch kind {
        case .hold(let c): label(c)
        case .holds(let c): label(c.first ?? 0)
        case .outside: Color.secondary.opacity(0.55)
        case .setAside(let short): short ? Color.orange.opacity(0.7) : Color.accentColor.opacity(0.3)
        case .room: Color.primary.opacity(0.07)
        case .reserve: Color.secondary.opacity(0.3)
        }
    }

    /// Waiting is always hatching: diagonal strokes over a faint fill of the same colour.
    static func hatch(_ context: inout GraphicsContext, _ rect: CGRect, _ color: Color) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.fill(Path(rect), with: .color(color.opacity(0.18)))
        var lines = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 3
        }
        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.stroke(lines, with: .color(color.opacity(0.85)), lineWidth: 1)
    }
}

/// Places its children in rows, wrapping where the next does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, bounds.width) {
            for (i, x) in zip(row.items, row.xs) {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [Int] = []; var xs: [CGFloat] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, _ width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + lineSpacing))
            }
            var row = rows[rows.count - 1]
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append(i)
            row.xs.append(x)
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
