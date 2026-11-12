import Foundation

/// Memory over time at one range's resolution, for the charts. A bucket keeps the one sample with
/// the most memory in use, whole, so the parts drawn for a moment all come from that moment.
public struct Series: Sendable {
    public enum Range: Sendable, CaseIterable {
        case quarterHour, hour, sixHours, day

        public var spanS: Int64 {
            switch self {
            case .quarterHour: 15 * 60
            case .hour: 60 * 60
            case .sixHours: 6 * 60 * 60
            case .day: 24 * 60 * 60
            }
        }

        public var resolutionS: Int64 {
            switch self {
            case .quarterHour: 2
            case .hour: 10
            case .sixHours: 60
            case .day: 5 * 60
            }
        }
    }

    /// A kept sample as the charts draw it, with `machine_mib` from `status`.
    public struct Point: Sendable, Equatable {
        public let timeNS: Int64
        /// `machine − headroom`.
        public let inUseMiB: Int64
        public let footprintMiB: [String: Int64]
        /// Memory in use less the footprints, at least 0.
        public let outsideMiB: Int64
        /// `machine − reserve − room`: in use plus what the holds may still grow into.
        public let reservedMiB: Int64
    }

    public struct Bucket: Sendable, Equatable {
        public let startNS: Int64
        /// Nil for a gap: nothing was recorded, or the reading failed. Never zero memory.
        public let point: Point?
    }

    /// A sample as the series keeps it; `ok` false is a failed reading.
    struct Reading: Sendable {
        let timeNS: Int64
        let ok: Bool
        let headroomMiB: Int64
        let reserveMiB: Int64
        let roomMiB: Int64
        let footprintMiB: [String: Int64]
    }

    public let range: Range
    private let maxSilenceNS: Int64
    private var kept: [Int64: Reading] = [:]
    private var failed: Set<Int64> = []
    private var silences: [ClosedRange<Int64>] = []
    private var first: Int64?
    private var last: Int64?

    /// `maxSilenceS`: a longer stretch without a reading is a gap; 6 s for samples, which come
    /// every 2 s, and more for the app's own polls, which come every 10 s while it is closed.
    public init(range: Range, maxSilenceS: Int64 = 6) {
        (self.range, self.maxSilenceNS) = (range, maxSilenceS * 1_000_000_000)
    }

    public mutating func add(_ s: SampleLine) {
        add(Reading(
            timeNS: s.timeNS, ok: s.headroomOK, headroomMiB: s.headroomMiB, reserveMiB: s.reserveMiB,
            roomMiB: s.roomMiB, footprintMiB: Dictionary(s.jobs.map { ($0.label, $0.footprintMiB) }, uniquingKeysWith: +)))
    }

    /// One of the app's own `status` readings, for the series kept while the record looks off.
    public mutating func add(_ doc: StatusDocument, at date: Date) {
        let t = Int64(date.timeIntervalSince1970 * 1e9)
        let footprints = Dictionary(doc.holds.map { ($0.label, $0.footprintMiB) }, uniquingKeysWith: +)
        guard let m = doc.mem, let h = m.headroomMiB, let r = m.reserveMiB, let room = m.roomMiB else {
            add(Reading(timeNS: t, ok: false, headroomMiB: 0, reserveMiB: 0, roomMiB: 0, footprintMiB: [:]))
            return
        }
        add(Reading(timeNS: t, ok: true, headroomMiB: h, reserveMiB: r, roomMiB: room, footprintMiB: footprints))
    }

    /// A reading not later than the last one is ignored: coreslot writes samples in time order.
    mutating func add(_ r: Reading) {
        if let last, r.timeNS <= last { return }
        if let last, r.timeNS - last > maxSilenceNS { silences.append(last...r.timeNS) }
        if first == nil { first = r.timeNS }
        let crossed = last.map { index($0) != index(r.timeNS) } ?? false
        last = r.timeNS
        let i = index(r.timeNS)
        if !r.ok {
            failed.insert(i)
        } else if kept[i].map({ r.headroomMiB < $0.headroomMiB }) ?? true {
            kept[i] = r
        }
        if crossed { prune(before: r.timeNS - range.spanS * 1_000_000_000) }
    }

    /// The range's buckets up to `now`, oldest first. A bucket with no reading inside a silence of
    /// at most `maxSilenceS` is left out, and the chart joins its neighbours.
    public func buckets(machineMiB: Int64, now: Date) -> [Bucket] {
        let res = range.resolutionS * 1_000_000_000
        let nowNS = Int64(now.timeIntervalSince1970 * 1e9)
        let startNS = nowNS - range.spanS * 1_000_000_000
        var unrecorded = silences
        if let first, let last {
            if first - startNS > maxSilenceNS { unrecorded.append(startNS...first) }
            if nowNS - last > maxSilenceNS { unrecorded.append(last...nowNS) }
        } else {
            unrecorded.append(startNS...nowNS)
        }
        var out: [Bucket] = []
        for i in index(startNS)...index(nowNS) {
            let s = i * res
            if failed.contains(i) {
                out.append(Bucket(startNS: s, point: nil))
            } else if let r = kept[i] {
                out.append(Bucket(startNS: s, point: point(r, machineMiB)))
            } else if unrecorded.contains(where: { $0.lowerBound < s + res && $0.upperBound > s }) {
                out.append(Bucket(startNS: s, point: nil))
            }
        }
        return out
    }

    private func point(_ r: Reading, _ machine: Int64) -> Point {
        let inUse = machine - r.headroomMiB
        let held = r.footprintMiB.values.reduce(0, +)
        return Point(
            timeNS: r.timeNS, inUseMiB: inUse, footprintMiB: r.footprintMiB, outsideMiB: max(0, inUse - held),
            reservedMiB: machine - r.reserveMiB - r.roomMiB)
    }

    private func index(_ t: Int64) -> Int64 {
        let res = range.resolutionS * 1_000_000_000
        return t >= 0 ? t / res : (t - res + 1) / res
    }

    private mutating func prune(before t: Int64) {
        let i = index(t)
        kept = kept.filter { $0.key >= i }
        failed = failed.filter { $0 >= i }
        silences.removeAll { $0.upperBound < t }
    }
}
