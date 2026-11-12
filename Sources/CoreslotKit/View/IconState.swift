import Foundation

/// What the menu bar icon shows for one reading.
public enum IconState: Sendable, Equatable {
    /// `fill` is the share of the machine coreslot has reserved, in quarters, 0 to 4.
    case idle, running(fill: Int), waiting(fill: Int), pressure, unavailable

    public init(_ reading: StatusReading) {
        guard case .document(let doc, let notices) = reading,
              !notices.contains(where: { if case .schema = $0 { true } else { false } })
        else {
            self = .unavailable
            return
        }
        let fill = Self.quarters(doc.mem)
        if ["yellow", "red", "floor"].contains(doc.watch.level) {
            self = .pressure
        } else if doc.tickets.contains(where: { $0.state != "dead" }) {
            self = .waiting(fill: fill)
        } else if !doc.holds.isEmpty {
            self = .running(fill: fill)
        } else {
            self = .idle
        }
    }

    /// `reserved_mib / machine_mib` to the nearest quarter; 0 without a machine size.
    static func quarters(_ mem: StatusDocument.Mem?) -> Int {
        guard let mem, let machine = mem.machineMiB, machine > 0 else { return 0 }
        let q = (Double(mem.reservedMiB) / Double(machine) * 4).rounded()
        return Int(min(4, max(0, q)))
    }
}
