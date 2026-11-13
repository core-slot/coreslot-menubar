import Foundation

/// The bar of the whole machine from one `status` reading: only sums and differences of its keys.
public struct MemoryBar: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A hold's footprint; the footprints add up to no more than memory in use.
        case hold(name: String, label: String)
        /// Memory in use less the footprints.
        case outside
        /// Inside the free memory: what coreslot set aside for the holds to grow into (from the
        /// left), the room left for new commands, and the reserve (from the right).
        case setAside, room, reserve
    }

    public struct Segment: Sendable, Equatable {
        public let kind: Kind
        public let mib: Int64
    }

    /// Left to right; together they are the machine's memory.
    public let segments: [Segment]
    /// `-room_mib` when the holds reserve more than the machine offers; the set-aside segment is
    /// then cut to what free memory has.
    public let shortfallMiB: Int64?
    /// `headroom_mib − reserve_mib − room_mib` unclipped, for the legend: "set aside X, Y short".
    public let setAsideMiB: Int64

    public init?(_ doc: StatusDocument) {
        guard let m = doc.mem, let machine = m.machineMiB, let headroom = m.headroomMiB,
              let reserve = m.reserveMiB, let room = m.roomMiB
        else { return nil }
        let free = min(max(0, headroom), machine)
        var left = machine - free
        var segments = doc.holds.map { h in
            let f = min(h.footprintMiB, left)
            left -= f
            return Segment(kind: .hold(name: h.name, label: h.label), mib: f)
        }
        segments.append(Segment(kind: .outside, mib: left))
        let reserveShown = min(reserve, free)
        setAsideMiB = headroom - reserve - room
        let setAside = min(max(0, setAsideMiB), free - reserveShown)
        segments += [
            Segment(kind: .setAside, mib: setAside),
            Segment(kind: .room, mib: free - reserveShown - setAside),
            Segment(kind: .reserve, mib: reserveShown),
        ]
        self.segments = segments
        shortfallMiB = room < 0 ? -room : nil
    }
}
