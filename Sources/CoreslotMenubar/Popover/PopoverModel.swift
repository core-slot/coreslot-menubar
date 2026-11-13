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
        let strip: RunStrip
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

/// The last 30 minutes and a forecast zone of a quarter of that after now, drawn as the timeline
/// draws its runs.
struct RunStrip {
    static let pastS: Int64 = 30 * 60

    let startNS: Int64
    let endNS: Int64
    let nowNS: Int64
    let rows: [TimelineModel.Row]

    func x(_ t: Int64) -> Double { Double(t - startNS) / Double(endNS - startNS) }
}

extension Store {
    var popover: PopoverModel {
        guard let reading else { return PopoverModel(level: nil, tone: .unknown, notices: [], body: .reading) }
        switch reading {
        case .problem(let p):
            let words = Words.problem(p)
            // Only the file chosen in Settings is run, so the fix is there, not an install.
            let fix = p == .notFound && chosenBinary != nil ? "The file chosen in Settings did not answer as coreslot: choose another there." : words.fix
            return PopoverModel(level: nil, tone: .unknown, notices: [], body: .unavailable(state: words.state, fix: fix))
        case .notices(let notices):
            return PopoverModel(level: nil, tone: .unknown, notices: notices.map(Words.notice), body: .noticeOnly)
        case .document(let doc, let notices):
            return PopoverModel(level: Words.level(doc), tone: tone(doc.watch.level), notices: notices.map(Words.notice), body: .live(live(doc)))
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

    private var nowNS: Int64 { now.nanosecondsSince1970 }

    private func live(_ doc: StatusDocument) -> PopoverModel.Live {
        let off = recordState == .looksOff
        let waiting = doc.tickets.filter { $0.state != "dead" }
        let rows = waiting.enumerated().map { waitingRow($0.element, first: $0.offset == 0, recordOff: off) }
        let totals = report.map { r in
            r.runs == 0 ? "Last 24 h: no runs"
                : "Last 24 h: \(r.runs) \(r.runs == 1 ? "run" : "runs") · median wait \(Formatting.duration(r.medianWaitS)) · longest \(Formatting.duration(r.longestWaitS))"
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
        m.largest = largestProcesses(3)
        return m
    }

    private func runningRow(_ h: StatusDocument.Hold) -> RunningRow {
        let typical = h.typicalS ?? 0
        let points = record.tracks.points(h.name)
        let peak = record.tracks.peak(h.name)
        var figures = "now \(Formatting.size(h.footprintMiB))"
        if let peak { figures += " · peak \(Formatting.size(peak))" }
        figures += " · reserved \(Formatting.size(h.needMiB))"
        let top = Double(max(1, peak ?? 0))
        return RunningRow(
            hold: h, label: SafeText.display(h.label), color: color(h.label),
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
            "usually \(Formatting.duration(Double(typical)))"
        } else {
            nil
        }
        return WaitingRow(
            ticket: t, label: SafeText.display(t.label), color: color(t.label), reason: reason,
            waited: "waited \(Formatting.duration(t.waitedS))", trailing: trailing,
            cancelRequested: cancelRequested.contains(t.id))
    }

    private func runs(ticketName: String) -> Runs.Attempt? { record.runs.waiting(ticketName: ticketName) }

    /// The runs of the last 30 minutes, the latest 10.
    private func strip(_ doc: StatusDocument, recordOff: Bool) -> RunStrip {
        let (now, past) = (nowNS, RunStrip.pastS * 1_000_000_000)
        let rows = runRows(doc, nowNS: now, recordOff: recordOff, fromNS: now - past)
        return RunStrip(startNS: now - past, endNS: now + past / 4, nowNS: now, rows: Array(rows.suffix(10)))
    }
}
