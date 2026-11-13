import CoreslotKit
import Foundation

/// The timeline window as numbers and words, built from what the store holds; the views lay it
/// out. Times are nanoseconds since the epoch, as `time_ns` counts.
struct TimelineModel {
    /// The visible stretch: `startNS` to `viewEndNS` is the range, and the forecast zone after it
    /// takes a fifth of the width, to `endNS`.
    let startNS: Int64
    let viewEndNS: Int64
    let endNS: Int64
    let nowNS: Int64
    let totals: [(title: String, value: String)]
    /// Nil with `empty`; `memory.chart` is nil when `status` gives no machine size.
    let memory: Memory?
    let strip: Strip?
    /// Why there is no memory chart, no reasons and no processes: one calm state, naming the
    /// configuration file that turns the record on.
    let empty: (looksOff: Bool, configFile: String)?
    let rows: [Row]
    /// The labels the filter offers, raw, in colour order.
    let labels: [String]

    func x(_ t: Int64) -> Double { Double(t - startNS) / Double(endNS - startNS) }

    struct Memory {
        let chart: Chart?
        let largest: String?
    }

    struct Chart {
        let machineMiB: Int64
        /// Runs of buckets with a reading, oldest first; a gap ends one.
        let segments: [[Point]]
        /// Label and colour, bottom to top above "outside".
        let layers: [(label: String, color: Int)]
        let peak: Point?
        /// `machine − reserve − room` of the latest `status`, drawn flat over the forecast zone.
        let reservedNowMiB: Int64?
    }

    struct Point: Identifiable {
        var id: Int64 { timeNS }
        var timeNS: Int64
        let inUseMiB: Int64
        let outsideMiB: Int64
        /// Per layer, in `layers` order.
        let footprintMiB: [Int64]
        let reservedMiB: Int64
    }

    struct Strip {
        /// Where any run waited.
        let waits: [(fromNS: Int64, toNS: Int64)]
        let reasons: [(fromNS: Int64, toNS: Int64, reason: String)]
        /// The reasons shown, in a fixed order, with their names.
        let legend: [(reason: String, name: String)]
    }

    struct Row: Identifiable {
        let id: String
        /// The run an attempt belongs to: its restarts share it.
        let run: String
        /// As the state directory has it, for the filter.
        let rawLabel: String
        let label: String
        let color: Int
        let waitFromNS: Int64?
        /// Nil for a wait that ended without a start.
        let runFromNS: Int64?
        let toNS: Int64
        let live: Bool
        let stopped: Bool
        let restart: Bool
        let timedOut: Bool
        /// A running hold's expected end, from `left_s`.
        let forecastEndNS: Int64?
        /// The first live ticket's expected start, from `expected_wait_s`.
        let forecastStartNS: Int64?
        /// The hover's lines.
        let detail: [String]
    }
}

extension Series.Range {
    var title: String {
        switch self {
        case .quarterHour: "15 min"
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        }
    }
}

extension Store {
    /// Nil without a document; `end` nil is live.
    func timeline(range: Series.Range, end: Date?, label: String?) -> TimelineModel? {
        guard let doc = document else { return nil }
        let nowNS = now.nanosecondsSince1970
        let span = range.spanS * 1_000_000_000
        let viewEnd = min(nowNS, max(nowNS - RecordReader.keepS * 1_000_000_000 + span, end?.nanosecondsSince1970 ?? nowNS))
        let (start, endNS) = (viewEnd - span, viewEnd + span / 4)
        let off = recordState == .looksOff
        let all = runRows(doc, nowNS: nowNS, recordOff: off, fromNS: start).filter { ($0.waitFromNS ?? $0.runFromNS ?? $0.toNS) <= endNS }
        let shown = all.filter { label == nil || $0.rawLabel == label }
        let chart = off ? nil : memoryChart(doc, range: range, startNS: start, endNS: endNS, nowNS: nowNS)
        // Samples are written only while a command runs, so an idle range holds none. The file is the
        // one the `coreslot` this app runs reads, in the environment it is run in.
        let environment = ProcessInfo.processInfo.environment.merging(chosenStateDir.map { ["CORESLOT_STATE_DIR": $0.path] } ?? [:]) { $1 }
        let empty = off || chart?.segments.isEmpty == true ? (looksOff: off, configFile: Locate.configFile(environment: environment)) : nil
        return TimelineModel(
            startNS: start, viewEndNS: viewEnd, endNS: endNS, nowNS: nowNS,
            totals: totals(doc, rows: shown, chart: chart, startNS: start, viewEndNS: viewEnd, recordOff: off),
            memory: empty == nil ? .init(chart: chart, largest: largestProcesses(5)) : nil,
            strip: empty == nil ? strip(all, fromNS: start, toNS: min(endNS, nowNS)) : nil, empty: empty,
            rows: shown,
            labels: labelColors.sorted { $0.value < $1.value }.map(\.key))
    }

    /// A label's colour, by the order the app first saw it.
    func color(_ label: String) -> Int { labelColors[label] ?? 0 }

    // MARK: rows

    /// The runs that end at or after `fromNS`, of the timeline and the popover's strip alike.
    /// `arrival_ns` and `created_ns` are a run's first arrival, also after a restart: a live
    /// attempt waited from its own `enqueue`, and a restart the record does not have waited for
    /// all it shows.
    func runRows(_ doc: StatusDocument, nowNS: Int64, recordOff: Bool, fromNS: Int64) -> [TimelineModel.Row] {
        var out: [TimelineModel.Row] = []
        if !recordOff && !record.runs.attempts.isEmpty {
            for a in record.runs.attempts.values {
                guard let end = a.end else { continue } // a live one is in `status`; one with no end was lost
                out.append(attemptRow(a, end: end))
            }
        } else {
            for (i, r) in record.finished.enumerated() { out.append(logRow(r, index: i)) }
        }
        for h in doc.holds {
            let peak = record.tracks.peak(h.name), a = record.runs.running(holdName: h.name)
            let waitFrom = a?.arrivalNS ?? (h.stops > 0 || (a?.key.attempt ?? 1) > 1 ? nil : h.arrivalNS)
            out.append(.init(
                id: h.name, run: h.name, rawLabel: h.label, label: SafeText.display(h.label), color: color(h.label), waitFromNS: waitFrom,
                runFromNS: h.startNS, toNS: nowNS, live: true, stopped: false, restart: h.stops > 0, timedOut: false,
                forecastEndNS: h.leftS.flatMap { $0 > 0 ? ahead(nowNS, $0) : nil }, forecastStartNS: nil,
                detail: [
                    SafeText.display(h.label) + (h.container == true ? " · container" : ""),
                    "waited " + (waitFrom.map { span($0, h.startNS) } ?? "before its restart"), "running since \(clock(h.startNS)), \(duration(h.startNS, nowNS))",
                    "needs \(Formatting.size(h.needMiB)) · now \(Formatting.size(h.footprintMiB))" + (peak.map { " · peak \(Formatting.size($0))" } ?? ""),
                    "finishes in " + Formatting.timeLeft(h.leftS),
                ] + (h.stops > 0 ? ["restarted after \(h.stops) memory \(h.stops == 1 ? "stop" : "stops")"] : [])))
        }
        let live = doc.tickets.filter { $0.state != "dead" }
        for (i, t) in live.enumerated() {
            let first = i == 0, from = t.name.flatMap { record.runs.waiting(ticketName: $0)?.arrivalNS } ?? t.createdNS
            out.append(.init(
                id: t.id, run: t.id, rawLabel: t.label, label: SafeText.display(t.label), color: color(t.label), waitFromNS: from, runFromNS: nil,
                toNS: nowNS, live: true, stopped: false, restart: false, timedOut: false, forecastEndNS: nil,
                forecastStartNS: first ? t.expectedWaitS.map { ahead(nowNS, $0) } : nil,
                detail: [
                    SafeText.display(t.label), "waiting since \(clock(from)), \(duration(from, nowNS))",
                    "needs \(Formatting.size(t.needMiB))",
                    first ? Formatting.firstTicketWait(t.expectedWaitS) : "behind \(i) in the queue",
                ]))
        }
        return out.filter { $0.toNS >= fromNS }
            .sorted { ($0.waitFromNS ?? $0.runFromNS ?? $0.toNS, $0.id) < ($1.waitFromNS ?? $1.runFromNS ?? $1.toNS, $1.id) }
    }

    private func attemptRow(_ a: Runs.Attempt, end: Runs.End) -> TimelineModel.Row {
        let from = a.arrivalNS ?? a.admittedNS ?? end.timeNS
        let watchdog = a.stoppedBy?.hasPrefix("watchdog_") == true
        var detail = [SafeText.display(a.label) + (a.key.attempt > 1 ? " · attempt \(a.key.attempt)" : "")]
        if let run = a.admittedNS {
            detail.append("waited \(span(from, run))")
            detail.append("ran \(span(run, end.timeNS))")
        } else {
            detail.append("waited \(span(from, end.timeNS)), then \(endWords(end.event))")
        }
        var figures: [String] = []
        if let need = a.needMiB { figures.append("needs \(Formatting.size(need))") }
        if let kib = a.record?.memPeakKiB { figures.append("peak \(Formatting.size(kib / 1024))") }
        if !figures.isEmpty { detail.append(figures.joined(separator: " · ")) }
        if end.event == "ended" {
            var exit = a.record.map { "exit status \($0.exit)" } ?? "exit status not recorded"
            if let s = a.signal { exit += " · killed by \(SafeText.display(s))" }
            detail.append(exit)
        }
        if watchdog { detail.append(a.stoppedBy == "watchdog_floor" ? "stopped by the watchdog: memory critically low" : "stopped by the watchdog: memory very tight") }
        if a.stoppedBy == "outside" { detail.append("killed by a signal coreslot did not send") }
        if a.failOpen == "timeout" { detail.append("went on outside the budget after its timeout") }
        return .init(
            id: "\(a.key.run)/\(a.key.attempt)", run: a.key.run, rawLabel: a.label, label: SafeText.display(a.label), color: color(a.label),
            waitFromNS: a.admittedNS == from ? nil : from, runFromNS: a.admittedNS, toNS: end.timeNS, live: false,
            stopped: watchdog, restart: a.key.attempt > 1, timedOut: a.failOpen == "timeout",
            forecastEndNS: nil, forecastStartNS: nil, detail: detail)
    }

    private func logRow(_ r: RunLogLine, index: Int) -> TimelineModel.Row {
        // In `Double`: seconds as large as the clamp lets through do not fit in nanoseconds.
        let clamp = { (t: Double) in Int64(min(max(t, 0), Double(Int64.max / 2))) }
        let ran = clamp(Double(r.timeNS) + r.waitedS * 1e9), end = clamp(Double(r.timeNS) + (r.waitedS + r.ranS) * 1e9)
        var detail = [SafeText.display(r.label), "waited \(span(r.timeNS, ran))", "ran \(span(ran, end))"]
        detail.append((r.memPeakKiB.map { "peak \(Formatting.size($0 / 1024)) · " } ?? "") + "exit status \(r.exit)")
        if r.stops > 0 { detail.append("stopped for memory") }
        if r.failOpen == "timeout" { detail.append("went on outside the budget after its timeout") }
        return .init(
            id: "log/\(index)", run: "log/\(index)", rawLabel: r.label, label: SafeText.display(r.label), color: color(r.label), waitFromNS: r.timeNS, runFromNS: ran,
            toNS: end, live: false, stopped: r.stops > 0, restart: false, timedOut: r.failOpen == "timeout",
            forecastEndNS: nil, forecastStartNS: nil, detail: detail)
    }

    private func endWords(_ event: String) -> String {
        switch event {
        case "cancelled": "withdrawn"
        case "interrupted": "interrupted by a signal"
        case "refused": "refused"
        case "timeout": "gave up at its timeout"
        case "not_started": "not started"
        default: SafeText.display(event)
        }
    }

    // MARK: memory

    /// Scrolled back, the forecast zone's fifth shows what was recorded after the range.
    private func memoryChart(_ doc: StatusDocument, range: Series.Range, startNS: Int64, endNS: Int64, nowNS: Int64) -> TimelineModel.Chart? {
        guard let machine = doc.mem?.machineMiB, machine > 0 else { return nil }
        // The finest series that still keeps the stretch shown: scrolled back, a coarser one.
        let source = Series.Range.allCases.first { $0.spanS >= range.spanS && nowNS - $0.spanS * 1_000_000_000 <= startNS } ?? .day
        let buckets = (record.series[source]?.buckets(machineMiB: machine, now: Date(nanoseconds: min(nowNS, endNS))) ?? [])
            .filter { $0.startNS + source.resolutionS * 1_000_000_000 > startNS }
        let labels = Set(buckets.flatMap { $0.point?.footprintMiB.keys.map { $0 } ?? [] })
        let layers = labels.sorted { (color($0), $0) < (color($1), $1) }.map { (label: $0, color: color($0)) }
        var segments: [[TimelineModel.Point]] = [], current: [TimelineModel.Point] = []
        let width = source.resolutionS * 1_000_000_000
        func close() {
            // A bucket alone is drawn across its width: one point draws no area and no line.
            if current.count == 1, let p = current.first {
                current = [p.timeNS / width * width, (p.timeNS / width + 1) * width].map { var q = p; q.timeNS = $0; return q }
            }
            if !current.isEmpty { segments.append(current) }
            current = []
        }
        for b in buckets {
            guard let p = b.point else { close(); continue }
            current.append(.init(
                timeNS: p.timeNS, inUseMiB: p.inUseMiB, outsideMiB: p.outsideMiB,
                footprintMiB: layers.map { p.footprintMiB[$0.label] ?? 0 }, reservedMiB: p.reservedMiB))
        }
        close()
        let reservedNow = doc.mem.flatMap { m in m.reserveMiB.flatMap { r in m.roomMiB.map { machine - r - $0 } } }
        return .init(
            machineMiB: machine, segments: segments, layers: layers,
            peak: segments.joined().max { $0.inUseMiB < $1.inUseMiB }, reservedNowMiB: endNS > nowNS ? reservedNow : nil)
    }

    /// A list of the largest processes, not of what is outside coreslot; "others" closes it. From
    /// `memory.top` and the Docker VM's largest process, `memory.vm`, unless `top` names it, of a
    /// line at most 2 minutes old by the series' time rule.
    func largestProcesses(_ count: Int) -> String? {
        guard let line = record.memory, placed(line.timeNS, nowNS: now.nanosecondsSince1970, spanS: 120) else { return nil }
        let largest = (line.top + [line.vm].compactMap { $0 }.filter { !line.top.contains($0) }).sorted { $0.footprintMiB > $1.footprintMiB }
        guard !largest.isEmpty else { return nil }
        return "Largest processes: " + largest.prefix(count).map { "\(SafeText.display($0.name)) \(Formatting.size($0.footprintMiB))" }
            .joined(separator: ", ") + ", others"
    }

    // MARK: strip and totals

    private func strip(_ rows: [TimelineModel.Row], fromNS: Int64, toNS: Int64) -> TimelineModel.Strip {
        let waits = rows.compactMap { r in r.waitFromNS.map { (fromNS: $0, toNS: r.runFromNS ?? r.toNS) } }
            .filter { $0.toNS > fromNS && $0.fromNS < toNS }
        let reasons = record.runs.headReasons(fromNS: fromNS, toNS: toNS).map { (fromNS: $0.fromNS, toNS: $0.toNS, reason: $0.reason) }
        let order = ["room_short", "behind_head", "behind_ticket", "section_busy", "watch_level", "watch_spacing", "restart_"]
        let present = Set(reasons.map { Self.reasonKey($0.reason) })
        var legend = order.filter(present.contains).map { (reason: $0, name: Words.reasonName($0 == "restart_" ? "restart_calm" : $0)!) }
        if present.contains("other") { legend.append((reason: "other", name: "Another reason")) }
        return .init(waits: waits, reasons: reasons, legend: legend)
    }

    /// The legend's key for a reason code: every restart reason is one.
    static func reasonKey(_ code: String) -> String {
        code.hasPrefix("restart_") ? "restart_" : Words.reasonName(code) == nil ? "other" : code
    }

    private func totals(
        _ doc: StatusDocument, rows: [TimelineModel.Row], chart: TimelineModel.Chart?, startNS: Int64, viewEndNS: Int64, recordOff: Bool
    ) -> [(title: String, value: String)] {
        let clip = { (a: Int64?, b: Int64?) -> Double in
            guard let a, let b else { return 0 }
            return Double(max(0, min(b, viewEndNS) - max(a, startNS))) / 1e9
        }
        let waited = rows.reduce(0) { $0 + clip($1.waitFromNS, $1.runFromNS ?? $1.toNS) }
        let ran = rows.reduce(0) { sum, r in sum + (r.runFromNS == nil ? 0 : clip(r.runFromNS, r.toNS)) }
        let runs = Set(rows.map(\.run)).count
        let peak = chart?.segments.joined().map { $0.footprintMiB.reduce(0, +) }.max()
        let outside = MemoryBar(doc)?.segments.first { $0.kind == .outside }?.mib
        return [
            ("Runs", "\(runs)"),
            ("Waited", Formatting.duration(waited)),
            ("Ran", Formatting.duration(ran)),
            ("Peak under coreslot", peak.map(Formatting.size) ?? (recordOff ? "not recorded" : "no reading")),
            ("Outside coreslot now", outside.map(Formatting.size) ?? "not read"),
        ]
    }

    /// `s` seconds after `now`, at most two days: a forecast past the zone is cut there anyway,
    /// and seconds as large as the clamp lets through do not fit in nanoseconds.
    private func ahead(_ nowNS: Int64, _ s: Int64) -> Int64 { nowNS + min(s, 2 * 86_400) * 1_000_000_000 }

    // MARK: words for times

    private func clock(_ ns: Int64) -> String { Self.clockFormat.string(from: Date(nanoseconds: ns)) }

    private func duration(_ a: Int64, _ b: Int64) -> String { Formatting.duration(Double(b - a) / 1e9) }

    private func span(_ a: Int64, _ b: Int64) -> String { "\(clock(a)) – \(clock(b)), \(duration(a, b))" }

    static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

extension Date {
    init(nanoseconds ns: Int64) { self.init(timeIntervalSince1970: Double(ns) / 1e9) }
}
