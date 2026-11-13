import Foundation

/// One line of `log/runs.jsonl`, one attempt, as
/// https://github.com/core-slot/coreslot/blob/v0.8.0/PROTOCOL.md#20-run-log defines it: the source
/// of finished runs while the telemetry record looks off. An absent optional key is unknown.
package struct RunLogLine: JSONLine, Sendable, Equatable {
    package let timeNS: Int64
    package let label: String
    package let waitedS: Double
    package let ranS: Double
    package let memPeakKiB: Int64?
    package let exit: Int64
    package let failOpen: String
    /// Set on the line of an attempt stopped for memory; 0 on every other.
    package let stops: Int64

    enum CodingKeys: String, CodingKey {
        case timeNS = "time_ns"
        case label
        case waitedS = "waited_s"
        case ranS = "ran_s"
        case memPeakKiB = "mem_peak_kib"
        case exit
        case failOpen = "fail_open"
        case stops
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeNS = try c.decode(.timeNS, in: Clamp.time)
        label = try c.decode(String.self, forKey: .label)
        (waitedS, ranS) = (try c.decodeSeconds(.waitedS), try c.decodeSeconds(.ranS))
        memPeakKiB = try c.decodeIfPresent(.memPeakKiB, in: Clamp.amount)
        exit = try c.decode(.exit, in: Clamp.signed)
        failOpen = try c.decode(String.self, forKey: .failOpen)
        stops = try c.decodeIfPresent(.stops, in: Clamp.amount) ?? 0
    }
}
