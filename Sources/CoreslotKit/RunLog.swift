import Foundation

/// One line of `log/runs.jsonl`, one attempt, as
/// https://github.com/core-slot/coreslot/blob/v0.8.0/PROTOCOL.md#20-run-log defines it: the source
/// of finished runs while the telemetry record looks off. An absent optional key is unknown.
public struct RunLogLine: Decodable, Sendable, Equatable {
    public let timeNS: Int64
    public let label: String
    public let waitedS: Double
    public let ranS: Double
    public let memPeakKiB: Int64?
    public let exit: Int64
    public let failOpen: String
    public let container: Bool
    /// Set on the line of an attempt stopped for memory; 0 on every other.
    public let stops: Int64

    enum CodingKeys: String, CodingKey {
        case timeNS = "time_ns"
        case label
        case waitedS = "waited_s"
        case ranS = "ran_s"
        case memPeakKiB = "mem_peak_kib"
        case exit
        case failOpen = "fail_open"
        case container, stops
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeNS = try c.decode(Int64.self, forKey: .timeNS)
        label = try c.decode(String.self, forKey: .label)
        waitedS = try c.decode(Double.self, forKey: .waitedS)
        ranS = try c.decode(Double.self, forKey: .ranS)
        memPeakKiB = try c.decodeIfPresent(Int64.self, forKey: .memPeakKiB)
        exit = try c.decode(Int64.self, forKey: .exit)
        failOpen = try c.decode(String.self, forKey: .failOpen)
        container = try c.decodeIfPresent(Bool.self, forKey: .container) ?? false
        stops = try c.decodeIfPresent(Int64.self, forKey: .stops) ?? 0
    }

    public init?(line: Data) {
        guard let r = try? JSONDecoder().decode(Self.self, from: line) else { return nil }
        self = r
    }
}
