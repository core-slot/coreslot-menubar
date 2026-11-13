import Foundation

/// Each live hold's footprint over its recent past, for the popover's sparklines: `Series` keys
/// footprints by label, and two holds of one label are two lines here. A bucket keeps its largest
/// reading, from the samples' `jobs` and the app's own polls alike.
public struct HoldTracks: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public let timeNS: Int64
        public let footprintMiB: Int64
    }

    public let resolutionS: Int64
    public let spanS: Int64
    private var tracks: [String: [Point]] = [:]

    public init(resolutionS: Int64 = 10, spanS: Int64 = 30 * 60) {
        (self.resolutionS, self.spanS) = (resolutionS, spanS)
    }

    /// A sample whose reading failed adds nothing: its gap is never zero memory.
    public mutating func add(_ s: SampleLine) {
        guard s.headroomOK else { return }
        for j in s.jobs { add(hold: j.hold, timeNS: s.timeNS, footprintMiB: j.footprintMiB) }
    }

    public mutating func add(_ doc: StatusDocument, at date: Date) {
        let t = date.nanosecondsSince1970
        for h in doc.holds { add(hold: h.name, timeNS: t, footprintMiB: h.footprintMiB) }
    }

    public mutating func add(hold: String, timeNS: Int64, footprintMiB: Int64) {
        var t = tracks[hold, default: []]
        let b = bucket(timeNS)
        // Lines of the older generation and polls interleave: insert in time order.
        let i = t.lastIndex { bucket($0.timeNS) <= b }
        if let i, bucket(t[i].timeNS) == b {
            if footprintMiB > t[i].footprintMiB { t[i] = Point(timeNS: timeNS, footprintMiB: footprintMiB) }
        } else {
            t.insert(Point(timeNS: timeNS, footprintMiB: footprintMiB), at: i.map { $0 + 1 } ?? 0)
        }
        let oldest = (t.last?.timeNS ?? timeNS) - spanS * 1_000_000_000
        t.removeAll { $0.timeNS < oldest }
        tracks[hold] = t
    }

    /// Forgets every hold but these, the live ones.
    public mutating func keep(only holds: Set<String>) {
        tracks = tracks.filter { holds.contains($0.key) }
    }

    public func points(_ hold: String) -> [Point] { tracks[hold] ?? [] }

    /// The largest footprint seen for the hold; nil when none was.
    public func peak(_ hold: String) -> Int64? { tracks[hold]?.map(\.footprintMiB).max() }

    private func bucket(_ t: Int64) -> Int64 { slot(t, resolutionS: resolutionS) }
}
