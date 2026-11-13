import Foundation

/// What the footer takes from `coreslot report --days 1 --json`: coreslot does the counting.
public struct Report: Decodable, Sendable, Equatable {
    public let runs: Int64
    /// Over the attempts that waited at least a second; 0 when none did.
    public let medianWaitS: Double
    public let longestWaitS: Double

    enum CodingKeys: String, CodingKey { case schema, runs, waits }
    enum WaitKeys: String, CodingKey {
        case median = "median_s"
        case longest = "longest_s"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.checkSchema(.schema)
        runs = try c.decode(Int64.self, forKey: .runs)
        let w = try c.nestedContainer(keyedBy: WaitKeys.self, forKey: .waits)
        medianWaitS = try w.decode(Double.self, forKey: .median)
        longestWaitS = try w.decode(Double.self, forKey: .longest)
    }
}
