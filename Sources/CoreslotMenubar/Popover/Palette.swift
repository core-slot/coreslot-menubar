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

    /// Waiting is always hatching: diagonal strokes over a faint fill of the same colour, each
    /// stroke cut to the rectangle, half a stroke inside it.
    static func hatch(_ sketch: inout Sketcher, _ rect: CGRect, _ color: Color) {
        guard rect.width > 0, rect.height > 0 else { return }
        sketch.fill(Path(rect), with: .color(color.opacity(0.18)))
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        guard r.width > 0, r.height > 0 else { return }
        var lines = Path()
        var x = rect.minX - rect.height
        while x < r.maxX {
            // A stroke rises one point for each point it runs right, from (x, rect.maxY).
            let (from, to) = (max(x + rect.maxY - r.maxY, r.minX), min(x + rect.maxY - r.minY, r.maxX))
            if from < to {
                lines.move(to: CGPoint(x: from, y: rect.maxY - (from - x)))
                lines.addLine(to: CGPoint(x: to, y: rect.maxY - (to - x)))
            }
            x += 3
        }
        sketch.stroke(lines, with: .color(color.opacity(0.85)), lineWidth: 1)
    }
}

/// Draws as a `Canvas` would, but as ordinary path and text views. Each redraw of a `Canvas`
/// takes about 50 MiB of graphics memory for a moment, and the views redraw on every reading;
/// paths and text take none.
struct Sketch: View {
    let draw: (inout Sketcher, CGSize) -> Void

    init(_ draw: @escaping (inout Sketcher, CGSize) -> Void) { self.draw = draw }

    var body: some View {
        GeometryReader { g in
            let items = Sketcher.items(draw, g.size)
            ZStack(alignment: .topLeading) {
                ForEach(items.indices, id: \.self) { items[$0].view }
            }
        }
        .contentShape(Rectangle())
    }
}

/// What a `Sketch` draws: fills, strokes and text, in order.
struct Sketcher {
    /// Spelled as a `GraphicsContext` shading is, `.color(_:)`.
    enum Ink { case color(Color) }

    fileprivate enum Item {
        case fill(Path, Color), stroke(Path, Color, StrokeStyle), text(Text, CGPoint)

        @ViewBuilder var view: some View {
            switch self {
            case .fill(let p, let c): p.fill(c)
            case .stroke(let p, let c, let style): p.stroke(c, style: style)
            case .text(let t, let at): t.position(at)
            }
        }
    }

    fileprivate var items: [Item] = []

    fileprivate static func items(_ draw: (inout Sketcher, CGSize) -> Void, _ size: CGSize) -> [Item] {
        var s = Sketcher()
        draw(&s, size)
        return s.items
    }

    mutating func fill(_ path: Path, with ink: Ink) {
        guard case .color(let c) = ink else { return }
        items.append(.fill(path, c))
    }

    mutating func stroke(_ path: Path, with ink: Ink, lineWidth: CGFloat = 1) {
        stroke(path, with: ink, style: StrokeStyle(lineWidth: lineWidth))
    }

    mutating func stroke(_ path: Path, with ink: Ink, style: StrokeStyle) {
        guard case .color(let c) = ink else { return }
        items.append(.stroke(path, c, style))
    }

    /// Centred at the point, as `GraphicsContext.draw(_:at:)` places it.
    mutating func draw(_ text: Text, at point: CGPoint) { items.append(.text(text, point)) }
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
