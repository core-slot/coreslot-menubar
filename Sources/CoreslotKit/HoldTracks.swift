import Foundation

/// Each live hold's footprint over its recent past, for the popover's sparklines: `Series` keys
/// footprints by label, and two holds of one label are two lines here. A bucket keeps its largest
/// reading, from the samples' `jobs` and the app's own polls alike. A point is placed by its time
/// against the caller's clock, by the series' rule (`placed`), so one line dated far ahead or a
/// clock that steps back costs the track nothing.
package struct HoldTracks: Sendable, Equatable {
    package struct Point: Sendable, Equatable {
        package let timeNS: Int64
        package let footprintMiB: Int64
    }

    package let resolutionS: Int64
    package let spanS: Int64
    private var tracks: [String: [Point]] = [:]

    package init(resolutionS: Int64 = 10, spanS: Int64 = 30 * 60) {
        (self.resolutionS, self.spanS) = (resolutionS, spanS)
    }

    /// A sample whose reading failed adds nothing: its gap is never zero memory.
    package mutating func add(_ s: SampleLine, now: Date) {
        guard s.headroomOK else { return }
        for j in s.jobs { add(hold: j.hold, timeNS: s.timeNS, footprintMiB: j.footprintMiB, now: now) }
    }

    /// A poll, taken at `date`, which is its now too.
    package mutating func add(_ doc: StatusDocument, at date: Date) {
        let t = date.nanosecondsSince1970
        for h in doc.holds { add(hold: h.name, timeNS: t, footprintMiB: h.footprintMiB, now: date) }
    }

    package mutating func add(hold: String, timeNS: Int64, footprintMiB: Int64, now: Date) {
        let nowNS = now.nanosecondsSince1970, spanNS = spanS * 1_000_000_000
        // As `Series` keeps its buckets: a span either side of now.
        var t = tracks[hold, default: []].filter { $0.timeNS >= nowNS - spanNS && $0.timeNS <= nowNS + spanNS }
        if placed(timeNS, nowNS: nowNS, spanS: spanS) {
            let b = bucket(timeNS)
            // Lines of the older generation and polls interleave: insert in time order.
            let i = t.lastIndex { bucket($0.timeNS) <= b }
            if let i, bucket(t[i].timeNS) == b {
                if footprintMiB > t[i].footprintMiB { t[i] = Point(timeNS: timeNS, footprintMiB: footprintMiB) }
            } else {
                t.insert(Point(timeNS: timeNS, footprintMiB: footprintMiB), at: i.map { $0 + 1 } ?? 0)
            }
        }
        tracks[hold] = t
    }

    /// Forgets every hold but these, the live ones.
    package mutating func keep(only holds: Set<String>) {
        tracks = tracks.filter { holds.contains($0.key) }
    }

    package func points(_ hold: String) -> [Point] { tracks[hold] ?? [] }

    /// The largest footprint seen for the hold; nil when none was.
    package func peak(_ hold: String) -> Int64? { tracks[hold]?.map(\.footprintMiB).max() }

    private func bucket(_ t: Int64) -> Int64 { slot(t, resolutionS: resolutionS) }
}
