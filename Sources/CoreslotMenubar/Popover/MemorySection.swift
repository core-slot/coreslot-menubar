import SwiftUI

struct MemorySection: View {
    let model: MemoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let unread = model.unread {
                Text(unread).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let inUse = model.inUse {
                    Text(inUse).font(.title2.weight(.semibold)).monospacedDigit()
                }
                if let of = model.ofMachine { Text(of).font(.callout).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if let free = model.free { Text(free).font(.callout).monospacedDigit() }
            }
            if !model.segments.isEmpty {
                MemoryBarView(segments: model.segments).frame(height: 10)
                FlowLayout {
                    ForEach(model.legend) { item in
                        HStack(spacing: 4) {
                            Swatch(kind: item.kind).frame(width: 8, height: 8)
                            Text(item.text)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            if let shortfall = model.shortfall {
                Label(shortfall, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let largest = model.largest {
                Text(largest).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The whole machine left to right; the promises inside the free part are drawn as such.
private struct MemoryBarView: View {
    let segments: [MemoryModel.Segment]

    var body: some View {
        Sketch { context, size in
            var x: CGFloat = 0
            for s in segments {
                let rect = CGRect(x: x, y: 0, width: size.width * s.fraction, height: size.height)
                x += rect.width
                switch s.kind {
                case .reserve:
                    Palette.hatch(&context, rect, .secondary)
                case .setAside:
                    context.fill(Path(rect), with: .color(Palette.fill(s.kind)))
                    context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Palette.fill(s.kind).opacity(1)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                default:
                    context.fill(Path(rect), with: .color(Palette.fill(s.kind)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

private struct Swatch: View {
    let kind: MemoryModel.Kind

    var body: some View {
        Sketch { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if kind == .reserve {
                Palette.hatch(&context, rect, .secondary)
            } else if case .holds(let colors) = kind, colors.count > 1 {
                let shown = colors.prefix(4), w = size.width / CGFloat(shown.count)
                for (i, c) in shown.enumerated() {
                    context.fill(Path(CGRect(x: CGFloat(i) * w, y: 0, width: w, height: size.height)), with: .color(Palette.label(c)))
                }
            } else {
                context.fill(Path(rect), with: .color(Palette.fill(kind)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
