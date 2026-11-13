import Charts
import CoreslotKit
import SwiftUI

/// Every chart of the window draws over the same stretch, after the gutter: `x` of the model
/// times the plot's width.
private func d(_ ns: Int64) -> Date { Date(nanoseconds: ns) }

/// Text in the gutter, right-aligned against the plot.
private struct Gutter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            content
        }
        .lineLimit(1)
        .frame(width: TimelineView.gutter - 24)
        .padding(.leading, 16)
        .padding(.trailing, 8)
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).padding(.leading, 16)
    }
}

/// Time ticks at round local times, a handful per range.
private func ticks(_ m: TimelineModel) -> [Int64] {
    let span = (m.viewEndNS - m.startNS) / 1_000_000_000
    let step: Int64 = span <= 15 * 60 ? 3 * 60 : span <= 3600 ? 10 * 60 : span <= 6 * 3600 ? 3600 : 3 * 3600
    let offset = Int64(TimeZone.current.secondsFromGMT(for: Date(nanoseconds: m.startNS)))
    var t = ((m.startNS / 1_000_000_000 + offset) / step + 1) * step - offset
    var out: [Int64] = []
    while t * 1_000_000_000 < m.endNS {
        out.append(t * 1_000_000_000)
        t += step
    }
    return out
}

struct TimelineMemory: View {
    let model: TimelineModel
    let memory: TimelineModel.Memory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Memory")
            if let chart = memory.chart {
                HStack(spacing: 0) {
                    YLabels(machineMiB: chart.machineMiB).frame(width: TimelineView.gutter)
                    MemoryChart(model: model, chart: chart)
                }
                .frame(height: 170)
                .padding(.trailing, TimelineView.trailing)
                FlowLayout(spacing: 14) {
                    Swatch(color: Palette.fill(.outside), text: "outside coreslot")
                    ForEach(chart.layers, id: \.label) { Swatch(color: Palette.label($0.color), text: SafeText.display($0.label)) }
                    DashSwatch(text: "reserved by coreslot")
                }
                .padding(.leading, TimelineView.gutter)
            } else {
                Text("Memory could not be read").foregroundStyle(.secondary).padding(.leading, TimelineView.gutter)
            }
            if let largest = memory.largest {
                Text(largest).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, TimelineView.gutter).padding(.trailing, TimelineView.trailing)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct YLabels: View {
    let machineMiB: Int64

    var body: some View {
        GeometryReader { g in
            ForEach([1.0, 0.5, 0.0], id: \.self) { f in
                Text(f == 0 ? "0" : Formatting.size(Int64(Double(machineMiB) * f)))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: TimelineView.gutter - 8, alignment: .trailing)
                    .position(x: (TimelineView.gutter - 8) / 2, y: g.size.height * (1 - f))
            }
        }
    }
}

/// Stacked areas on one axis from 0 to the machine's memory: outside coreslot at the bottom, then
/// each label's footprint; the reserved line dashed; gaps as gaps; the peak marked.
private struct MemoryChart: View {
    let model: TimelineModel
    let chart: TimelineModel.Chart
    private static let dashed = StrokeStyle(lineWidth: 1, dash: [4, 3])

    var body: some View {
        Chart {
            RectangleMark(
                xStart: .value("time", d(max(model.nowNS, model.startNS))), xEnd: .value("time", d(model.endNS)),
                yStart: .value("MiB", 0.0), yEnd: .value("MiB", Double(chart.machineMiB)))
                .foregroundStyle(Color.primary.opacity(model.nowNS < model.endNS ? 0.04 : 0))
            ForEach([0.5, 1.0], id: \.self) { f in
                RuleMark(y: .value("MiB", Double(chart.machineMiB) * f)).foregroundStyle(Color.primary.opacity(0.08)).lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            ForEach(ticks(model), id: \.self) { t in
                RuleMark(x: .value("time", d(t))).foregroundStyle(Color.primary.opacity(0.06)).lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            ForEach(Array(chart.segments.enumerated()), id: \.offset) { si, segment in
                ForEach(segment) { p in areas(p, segment: si) }
            }
            if let peak = chart.peak {
                PointMark(x: .value("time", d(peak.timeNS)), y: .value("MiB", Double(peak.inUseMiB)))
                    .symbolSize(24)
                    .foregroundStyle(Color.primary)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("peak \(Formatting.size(peak.inUseMiB))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let reserved = chart.reservedNowMiB {
                ForEach([model.nowNS, model.endNS], id: \.self) { t in
                    LineMark(x: .value("time", d(t)), y: .value("MiB", Double(reserved)), series: .value("series", "forecast"))
                        .foregroundStyle(Color.primary.opacity(0.6)).lineStyle(Self.dashed)
                }
            }
            if model.nowNS <= model.endNS {
                RuleMark(x: .value("time", d(model.nowNS))).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: d(model.startNS)...d(model.endNS))
        .chartYScale(domain: 0...Double(chart.machineMiB))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityLabel("Memory over the range")
    }

    @ChartContentBuilder
    private func areas(_ p: TimelineModel.Point, segment si: Int) -> some ChartContent {
        let x = PlottableValue.value("time", d(p.timeNS))
        AreaMark(x: x, yStart: .value("MiB", 0.0), yEnd: .value("MiB", Double(p.outsideMiB)), series: .value("series", "outside \(si)"))
            .foregroundStyle(Palette.fill(.outside))
        ForEach(Array(chart.layers.enumerated()), id: \.offset) { li, layer in
            let low = Double(p.outsideMiB + p.footprintMiB.prefix(li).reduce(0, +))
            AreaMark(x: x, yStart: .value("MiB", low), yEnd: .value("MiB", low + Double(p.footprintMiB[li])), series: .value("series", "\(li) \(si)"))
                .foregroundStyle(Palette.label(layer.color))
        }
        LineMark(x: x, y: .value("MiB", Double(p.reservedMiB)), series: .value("series", "reserved \(si)"))
            .foregroundStyle(Color.primary.opacity(0.6)).lineStyle(Self.dashed)
    }
}

/// The reason of the head of the queue whenever anything waited, with a legend in words.
struct TimelineStrip: View {
    let model: TimelineModel
    let strip: TimelineModel.Strip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Gutter { Text("Why they wait").font(.subheadline.weight(.semibold)) }
                Canvas { context, size in draw(&context, size) }
                    .frame(height: 12)
                    .padding(.trailing, TimelineView.trailing)
                    .accessibilityHidden(true)
            }
            FlowLayout(spacing: 14) {
                ForEach(strip.legend, id: \.reason) { Swatch(color: reasonColor($0.reason), text: $0.name) }
                HatchSwatch(text: "waiting, no reason recorded")
            }
            .padding(.leading, TimelineView.gutter)
        }
        .padding(.vertical, 10)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let px = { (t: Int64) in size.width * min(1, max(0, model.x(t))) }
        for w in strip.waits {
            Palette.hatch(&context, CGRect(x: px(w.fromNS), y: 0, width: px(w.toNS) - px(w.fromNS), height: size.height), .secondary)
        }
        for r in strip.reasons {
            let rect = CGRect(x: px(r.fromNS), y: 0, width: max(1, px(r.toNS) - px(r.fromNS)), height: size.height)
            context.fill(Path(rect), with: .color(reasonColor(Store.reasonKey(r.reason))))
        }
        nowLine(&context, size, model)
    }
}

/// One row per run in the range: hatched while waiting, solid while running, the forecast dashed.
struct TimelineRuns: View {
    let model: TimelineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Gutter { Text("Runs").font(.subheadline.weight(.semibold)) }
                TimeAxis(model: model).frame(height: 14).padding(.trailing, TimelineView.trailing)
            }
            if model.rows.isEmpty {
                Text("No runs in this range").foregroundStyle(.secondary).padding(.leading, TimelineView.gutter).padding(.vertical, 6)
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 0) {
                            Gutter {
                                Circle().fill(Palette.label(row.color)).frame(width: 6, height: 6)
                                Text(row.label).font(.caption).truncationMode(.middle)
                            }
                            RowBar(model: model, row: row).frame(height: 10).padding(.trailing, TimelineView.trailing)
                        }
                        .frame(height: 18)
                        .contentShape(Rectangle())
                        .help(row.detail.joined(separator: "\n"))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.detail.joined(separator: ", "))
                    }
                }
            }
            FlowLayout(spacing: 14) {
                HatchSwatch(text: "waiting")
                Swatch(color: .secondary, text: "running")
                DashSwatch(text: "forecast")
                Text("\(Image(systemName: "bolt.fill")) stopped by the watchdog")
                Text("\(Image(systemName: "arrow.clockwise")) its restart")
                Text("\(Image(systemName: "clock.badge.exclamationmark")) outside the budget after a timeout")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, TimelineView.gutter)
            .padding(.bottom, 10)
        }
        .padding(.top, 10)
    }
}

private struct TimeAxis: View {
    let model: TimelineModel

    var body: some View {
        Canvas { context, size in
            for t in ticks(model) {
                let x = size.width * model.x(t)
                let text = Text(TimelineView.minutes.string(from: Date(nanoseconds: t))).font(.caption2).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: x, y: size.height / 2))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RowBar: View {
    let model: TimelineModel
    let row: TimelineModel.Row

    var body: some View {
        Canvas { context, size in draw(&context, size) }.accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let px = { (t: Int64) in size.width * min(1, max(0, model.x(t))) }
        let h = size.height
        let color = Palette.label(row.color)
        if model.nowNS < model.endNS {
            context.fill(Path(CGRect(x: px(model.nowNS), y: 0, width: size.width - px(model.nowNS), height: h)), with: .color(.primary.opacity(0.04)))
        }
        if let from = row.waitFromNS {
            Palette.hatch(&context, CGRect(x: px(from), y: 0, width: px(row.runFromNS ?? row.toNS) - px(from), height: h), color)
        }
        if let run = row.runFromNS {
            let rect = CGRect(x: px(run), y: 0, width: max(1.5, px(row.toNS) - px(run)), height: h)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
        }
        let dashed = StrokeStyle(lineWidth: 1, dash: [3, 2])
        if let end = row.forecastEndNS {
            let rect = CGRect(x: px(model.nowNS), y: 0, width: px(end) - px(model.nowNS), height: h).insetBy(dx: 0.5, dy: 0.5)
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), style: dashed)
        }
        if let start = row.forecastStartNS {
            var tick = Path()
            tick.move(to: CGPoint(x: px(start), y: -1))
            tick.addLine(to: CGPoint(x: px(start), y: h + 1))
            context.stroke(tick, with: .color(color), style: dashed)
        }
        var marks: [(String, CGFloat)] = []
        if row.restart { marks.append(("arrow.clockwise", px(row.waitFromNS ?? row.runFromNS ?? row.toNS) - 7)) }
        if row.timedOut, let run = row.runFromNS { marks.append(("clock.badge.exclamationmark", px(run) + 7)) }
        if row.stopped { marks.append(("bolt.fill", px(row.toNS) + 7)) }
        for (name, x) in marks {
            context.draw(Text(Image(systemName: name)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.primary), at: CGPoint(x: x, y: h / 2))
        }
        nowLine(&context, size, model)
    }
}

private func nowLine(_ context: inout GraphicsContext, _ size: CGSize, _ m: TimelineModel) {
    guard m.nowNS <= m.endNS else { return }
    var now = Path()
    let x = size.width * m.x(m.nowNS)
    now.move(to: CGPoint(x: x, y: 0))
    now.addLine(to: CGPoint(x: x, y: size.height))
    context.stroke(now, with: .color(.secondary), lineWidth: 1)
}

/// A reason's colour, always beside its name in the legend.
private func reasonColor(_ key: String) -> Color {
    switch key {
    case "room_short": .orange
    case "behind_head": .blue
    case "behind_ticket": .teal
    case "section_busy": .gray
    case "watch_level": .red
    case "watch_spacing": .pink
    case "restart_": .purple
    default: .brown
    }
}

private struct Swatch: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct HatchSwatch: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Canvas { context, size in Palette.hatch(&context, CGRect(origin: .zero, size: size), .secondary) }.frame(width: 10, height: 8)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct DashSwatch: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(p, with: .color(.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(width: 14, height: 8)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
