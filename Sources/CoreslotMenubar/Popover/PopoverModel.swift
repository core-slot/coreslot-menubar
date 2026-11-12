import CoreslotKit
import Foundation

/// The popover as text and fractions, built from what the store holds; the views only lay it out.
struct PopoverModel {
    enum Tone { case calm, tight, critical, unknown }

    enum Body {
        case reading
        case unavailable(state: String, fix: String)
        /// A document of another schema: the header's notice is all there is.
        case noticeOnly
        case live(Live)
    }

    struct Live {
        let memory: MemoryModel
        let running: [RunningRow]
        let waiting: [WaitingRow]
        /// Said under the waiting rows when the record looks off and their reasons are missing.
        let recordNote: String?
        let strip: StripModel
        let totals: String?
    }

    let level: String?
    let tone: Tone
    let notices: [String]
    let body: Body
}

struct MemoryModel {
    enum Kind: Equatable {
        case hold(color: Int), outside, setAside(short: Bool), room, reserve
        /// The legend's swatch for every hold at once.
        case holds(colors: [Int])
    }

    struct Segment: Identifiable {
        let id: Int
        let kind: Kind
        let fraction: Double
    }

    struct LegendItem: Identifiable {
        var id: String { text }
        let kind: Kind
        let text: String
    }

    var inUse: String?
    var ofMachine: String?
    var free: String?
    var segments: [Segment] = []
    var legend: [LegendItem] = []
    var shortfall: String?
    var largest: String?
    var unread: String?
}

struct RunningRow: Identifiable {
    var id: String { hold.name }
    let hold: StatusDocument.Hold
    let label: String
    let color: Int
    let finishes: String
    /// Elapsed against the typical run time, 0 to 1; nil without a typical run time.
    let progress: Double?
    let figures: String
    /// The footprint over the hold's recent past, 0 to 1 of its peak; empty below two points.
    let spark: [Double]
    let peakIndex: Int?
    let stoppable: Bool
    let quiet: String
}

struct WaitingRow: Identifiable {
    var id: String { ticket.id }
    let ticket: StatusDocument.Ticket
    let label: String
    let color: Int
    let reason: String?
    let waited: String
    let trailing: String?
    /// coreslot accepted a cancel; the row says so until the ticket leaves the queue.
    let cancelRequested: Bool
}

/// The last 30 minutes and a forecast zone of a fifth of the width, as fractions of the width.
struct StripModel {
    static let pastS: Int64 = 30 * 60
    static let nowX = 0.8

    struct Bar: Identifiable {
        let id: String
        let color: Int
        let waitFrom: Double
        /// Nil for a wait that ended without a start.
        let runFrom: Double?
        let to: Double
    }

    /// A dashed outline: a running command's expected end, or the first in line's expected start.
    struct Forecast: Identifiable {
        let id: String
        let color: Int
        let from: Double
        let to: Double
        let row: Int?
    }

    let bars: [Bar]
    let forecasts: [Forecast]
}

extension Store {
    var popover: PopoverModel {
        guard let reading else { return PopoverModel(level: nil, tone: .unknown, notices: [], body: .reading) }
        switch reading {
        case .problem(let p):
            let words = Words.problem(p)
            return PopoverModel(level: nil, tone: .unknown, notices: [], body: .unavailable(state: words.state, fix: words.fix))
        case .document(_, let notices):
            let said = notices.compactMap(Words.notice)
            guard let doc = document else { return PopoverModel(level: nil, tone: .unknown, notices: said, body: .noticeOnly) }
            return PopoverModel(level: Words.level(doc.watch), tone: tone(doc.watch.level), notices: said, body: .live(live(doc)))
        }
    }

    private func tone(_ level: String) -> PopoverModel.Tone {
        switch level {
        case "green": .calm
        case "yellow": .tight
        case "red", "floor": .critical
        default: .unknown
        }
    }

    private var nowNS: Int64 { Int64(now.timeIntervalSince1970 * 1e9) }

    private func color(_ label: String) -> Int { labelColors[label] ?? 0 }

    private func live(_ doc: StatusDocument) -> PopoverModel.Live {
        let off = recordState == .looksOff
        let waiting = doc.tickets.filter { $0.state != "dead" }
        let rows = waiting.enumerated().map { waitingRow($0.element, first: $0.offset == 0, recordOff: off) }
        let totals = report.map { r in
            r.runs == 0 ? "Last 24 h: no runs"
                : "Last 24 h: \(r.runs) \(r.runs == 1 ? "run" : "runs") · median wait \(Formatting.duration(Int64(r.medianWaitS.rounded()))) · longest \(Formatting.duration(Int64(r.longestWaitS.rounded())))"
        }
        return PopoverModel.Live(
            memory: memory(doc), running: doc.holds.map(runningRow), waiting: rows,
            recordNote: off && !rows.isEmpty ? "coreslot's local record looks off, so no reasons or usual times are shown." : nil,
            strip: strip(doc, recordOff: off), totals: totals)
    }

    private func memory(_ doc: StatusDocument) -> MemoryModel {
        var m = MemoryModel()
        guard let mem = doc.mem else {
            m.unread = "Memory could not be read"
            return m
        }
        m.free = "\(Formatting.size(mem.freeMiB)) free for new commands"
        guard let bar = MemoryBar(doc), let machine = mem.machineMiB, machine > 0 else {
            m.free! += " · \(Formatting.size(mem.reservedMiB)) reserved"
            return m
        }
        var held: Int64 = 0, inUse: Int64 = 0
        m.segments = bar.segments.enumerated().map { i, s in
            let kind: MemoryModel.Kind
            switch s.kind {
            case .hold(_, let label):
                kind = .hold(color: color(label))
                held += s.mib
                inUse += s.mib
            case .outside:
                kind = .outside
                inUse += s.mib
            case .setAside: kind = .setAside(short: bar.shortfallMiB != nil)
            case .room: kind = .room
            case .reserve: kind = .reserve
            }
            return MemoryModel.Segment(id: i, kind: kind, fraction: Double(s.mib) / Double(machine))
        }
        m.inUse = Formatting.size(inUse)
        m.ofMachine = "in use of \(Formatting.size(machine))"
        let part = { (k: MemoryBar.Kind) in bar.segments.first { $0.kind == k }?.mib ?? 0 }
        if !doc.holds.isEmpty { m.legend.append(.init(kind: .holds(colors: doc.holds.map { color($0.label) }), text: "coreslot \(Formatting.size(held))")) }
        m.legend.append(.init(kind: .outside, text: "outside \(Formatting.size(part(.outside)))"))
        if bar.setAsideMiB > 0 { m.legend.append(.init(kind: .setAside(short: bar.shortfallMiB != nil), text: "set aside \(Formatting.size(bar.setAsideMiB))")) }
        m.legend.append(.init(kind: .room, text: "free \(Formatting.size(part(.room)))"))
        m.legend.append(.init(kind: .reserve, text: "reserve \(Formatting.size(part(.reserve)))"))
        if let short = bar.shortfallMiB {
            m.shortfall = "Set aside \(Formatting.size(bar.setAsideMiB)), \(Formatting.size(short)) short"
        }
        // A list of the largest processes, not of what is outside coreslot; "others" closes it.
        if let line = record.memory, !line.top.isEmpty, nowNS - line.timeNS <= 120_000_000_000 {
            let named = line.top.prefix(3).map { "\(SafeText.display($0.name)) \(Formatting.size($0.footprintMiB))" }
            m.largest = "Largest processes: " + named.joined(separator: ", ") + ", others"
        }
        return m
    }

    private func runningRow(_ h: StatusDocument.Hold) -> RunningRow {
        let finishes = (h.leftS ?? 0) > 0 ? "finishes in " + Formatting.timeLeft(h.leftS) : Formatting.timeLeft(h.leftS)
        let typical = h.typicalS ?? 0
        let points = record.tracks.points(h.name)
        let peak = record.tracks.peak(h.name)
        var figures = "now \(Formatting.size(h.footprintMiB))"
        if let peak { figures += " · peak \(Formatting.size(peak))" }
        figures += " · reserved \(Formatting.size(h.needMiB))"
        let top = Double(max(1, peak ?? 0))
        return RunningRow(
            hold: h, label: SafeText.display(h.label), color: color(h.label), finishes: finishes,
            progress: typical > 0 ? min(1, h.heldForS / Double(typical)) : nil, figures: figures,
            spark: points.count >= 2 ? points.map { Double($0.footprintMiB) / top } : [],
            peakIndex: points.count >= 2 ? points.lastIndex { $0.footprintMiB == peak } : nil,
            stoppable: h.stoppable == true && !unchecked.contains(h.name),
            quiet: Words.quietLine(container: h.container == true, processChecked: !unchecked.contains(h.name)))
    }

    private func waitingRow(_ t: StatusDocument.Ticket, first: Bool, recordOff: Bool) -> WaitingRow {
        let attempt = recordOff ? nil : t.name.flatMap { runs(ticketName: $0) }
        let reason = attempt.flatMap { a in
            a.waiting.flatMap { w in
                Words.reason(w, needMiB: t.needMiB, realMemory: a.realMemory, ageS: max(0, (nowNS - (a.waitingNS ?? nowNS)) / 1_000_000_000))
            }
        }
        let trailing: String? = if first {
            Formatting.firstTicketWait(t.expectedWaitS)
        } else if let typical = attempt?.typicalS, typical > 0 {
            "usually \(Formatting.duration(typical))"
        } else {
            nil
        }
        return WaitingRow(
            ticket: t, label: SafeText.display(t.label), color: color(t.label), reason: reason,
            waited: "waited \(Formatting.duration(Int64(t.waitedS.rounded())))", trailing: trailing,
            cancelRequested: cancelRequested.contains(t.id))
    }

    private func runs(ticketName: String) -> Runs.Attempt? { record.runs.waiting(ticketName: ticketName) }

    private func strip(_ doc: StatusDocument, recordOff: Bool) -> StripModel {
        let now = nowNS, from = now - StripModel.pastS * 1_000_000_000
        let x = { (t: Int64) in min(1, max(0, StripModel.nowX * Double(t - from) / Double(now - from))) }
        var bars: [StripModel.Bar] = []
        let attempts = record.runs.attempts.values.filter { $0.end.map { $0.timeNS >= from } ?? false }
        if !recordOff && !record.runs.attempts.isEmpty {
            for a in attempts {
                guard let end = a.end else { continue }
                let start = a.arrivalNS ?? a.admittedNS ?? end.timeNS
                bars.append(.init(
                    id: "\(a.key.run)/\(a.key.attempt)", color: color(a.label), waitFrom: x(start),
                    runFrom: a.admittedNS.map(x), to: x(end.timeNS)))
            }
        } else {
            for (i, r) in record.finished.enumerated() {
                let ran = r.timeNS + Int64(r.waitedS * 1e9), end = ran + Int64(r.ranS * 1e9)
                guard end >= from else { continue }
                bars.append(.init(id: "log/\(i)", color: color(r.label), waitFrom: x(r.timeNS), runFrom: x(ran), to: x(end)))
            }
        }
        for h in doc.holds {
            bars.append(.init(id: h.name, color: color(h.label), waitFrom: x(h.arrivalNS), runFrom: x(h.startNS), to: x(now)))
        }
        for t in doc.tickets where t.state != "dead" {
            bars.append(.init(id: t.id, color: color(t.label), waitFrom: x(t.createdNS), runFrom: nil, to: x(now)))
        }
        bars = Array(bars.sorted { $0.waitFrom < $1.waitFrom }.suffix(10))
        let scale = (1 - StripModel.nowX) / Double(StripModel.pastS / 4)
        var forecasts: [StripModel.Forecast] = []
        for h in doc.holds {
            guard let left = h.leftS, left > 0 else { continue }
            forecasts.append(.init(
                id: h.name, color: color(h.label), from: StripModel.nowX, to: min(1, StripModel.nowX + Double(left) * scale),
                row: bars.firstIndex { $0.id == h.name }))
        }
        if let first = doc.tickets.first(where: { $0.state != "dead" }), let wait = first.expectedWaitS {
            let at = min(1, StripModel.nowX + Double(wait) * scale)
            forecasts.append(.init(id: first.id, color: color(first.label), from: at, to: at, row: bars.firstIndex { $0.id == first.id }))
        }
        return StripModel(bars: bars, forecasts: forecasts)
    }
}
