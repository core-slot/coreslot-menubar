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

    /// Samples come every 2 s; which slots of 2 s hold one is kept for the whole span.
    static let slotS: Int64 = 2
    /// More empty slots than this in a row, over 6 s, are a gap.
    static let maxEmptySlots = 3
    /// How far past the caller's now a sample may be dated and still be placed.
    static let aheadNS: Int64 = 60_000_000_000

    public let range: Range
    /// By bucket: the placed sample with the most memory in use.
    private(set) var kept: [Int64: Reading] = [:]
    /// Two bits per slot, 32 slots to a word, by word: a reading was placed there, a failed one was.
    private(set) var presence: [Int64: UInt64] = [:]
    /// The bucket of the caller's now that the series was last pruned for.
    private var prunedFor: Int64?

    public init(range: Range) { self.range = range }

    public mutating func add(_ s: SampleLine, now: Date) {
        add(Reading(
            timeNS: s.timeNS, ok: s.headroomOK, headroomMiB: s.headroomMiB, reserveMiB: s.reserveMiB,
            roomMiB: s.roomMiB, footprintMiB: Dictionary(s.jobs.map { ($0.label, $0.footprintMiB) }, uniquingKeysWith: +)),
            now: now)
    }

    /// `time_ns` is the wall clock, which can step, so a sample is placed by its time alone, in
    /// whatever order it comes: nothing depends on a previous sample. One dated more than
    /// `aheadNS` past `now`, the caller's own clock, or before the span, is not placed.
    mutating func add(_ r: Reading, now: Date) {
        let nowNS = now.nanosecondsSince1970
        prune(nowNS)
        guard r.timeNS <= nowNS + Self.aheadNS, r.timeNS >= nowNS - range.spanS * 1_000_000_000 else { return }
        let s = slot(r.timeNS, resolutionS: Self.slotS)
        presence[s >> 5, default: 0] |= UInt64(r.ok ? 1 : 2) << UInt64((s & 31) * 2)
        guard r.ok else { return }
        let i = index(r.timeNS)
        // The most memory in use, the least headroom; between equals the later, whatever the order.
        if kept[i].map({ (r.headroomMiB, -r.timeNS) < ($0.headroomMiB, -$0.timeNS) }) ?? true { kept[i] = r }
    }

    /// The range's buckets up to `now`, oldest first. A bucket that holds a failed reading, or
    /// none and lies in more than `maxEmptySlots` empty slots in a row, is a gap; one with no
    /// reading among fewer empty slots is left out, and the chart joins its neighbours.
    public func buckets(machineMiB: Int64, now: Date) -> [Bucket] {
        let nowNS = now.nanosecondsSince1970
        let perBucket = range.resolutionS / Self.slotS
        let (from, to) = (index(nowNS - range.spanS * 1_000_000_000), index(nowNS))
        // The slots from the first bucket's to now's.
        let (first, last) = (from * perBucket, slot(nowNS, resolutionS: Self.slotS))
        let state = (first...last).map { s in (presence[s >> 5] ?? 0) >> UInt64((s & 31) * 2) & 3 }
        var run = [Int](repeating: 0, count: state.count)
        var i = 0
        while i < state.count {
            guard state[i] == 0 else { i += 1; continue }
            var j = i
            while j < state.count && state[j] == 0 { j += 1 }
            for k in i..<j { run[k] = j - i }
            i = j
        }
        var out: [Bucket] = []
        for b in from...to {
            let slots = Int(b * perBucket - first)..<Int(min((b + 1) * perBucket, last + 1) - first)
            if slots.contains(where: { state[$0] & 2 != 0 }) {
                out.append(Bucket(startNS: b * range.resolutionS * 1_000_000_000, point: nil))
            } else if let r = kept[b] {
                out.append(Bucket(startNS: b * range.resolutionS * 1_000_000_000, point: point(r, machineMiB)))
            } else if slots.contains(where: { run[$0] > Self.maxEmptySlots }) {
                out.append(Bucket(startNS: b * range.resolutionS * 1_000_000_000, point: nil))
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

    private func index(_ t: Int64) -> Int64 { slot(t, resolutionS: range.resolutionS) }

    /// Keeps the buckets within a span on either side of the caller's now; once per bucket of now.
    private mutating func prune(_ nowNS: Int64) {
        let i = index(nowNS)
        guard prunedFor != i else { return }
        prunedFor = i
        let span = range.spanS / range.resolutionS
        let perBucket = range.resolutionS / Self.slotS
        kept = kept.filter { (i - span...i + span).contains($0.key) }
        presence = presence.filter { (((i - span) * perBucket) >> 5...((i + span + 1) * perBucket) >> 5).contains($0.key) }
    }
}

/// The slot of `resolutionS` seconds that a time falls in, counted from the epoch.
func slot(_ timeNS: Int64, resolutionS: Int64) -> Int64 { timeNS / (resolutionS * 1_000_000_000) }

extension Date {
    /// As `time_ns` counts: nanoseconds since the epoch.
    public var nanosecondsSince1970: Int64 { Int64(timeIntervalSince1970 * 1e9) }
}
