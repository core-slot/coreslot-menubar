import Foundation

// The telemetry lines the app reads, as
// https://github.com/core-slot/coreslot/blob/v0.8.0/docs/telemetry.md defines them: a line of a
// schema `v` other than 1 is skipped, an unknown key is ignored, a line that does not parse is nil.

/// One line of `samples.jsonl`.
public struct SampleLine: Decodable, Sendable, Equatable {
    public let timeNS: Int64
    public let level: String
    public let headroomOK: Bool
    public let headroomMiB: Int64
    public let reserveMiB: Int64
    public let roomMiB: Int64
    public let liveHolds: Int64
    public let jobs: [Job]

    public struct Job: Decodable, Sendable, Equatable {
        public let hold: String
        public let label: String
        public let footprintMiB: Int64

        enum CodingKeys: String, CodingKey {
            case hold, label
            case footprintMiB = "footprint_mib"
        }
    }

    enum CodingKeys: String, CodingKey {
        case v
        case timeNS = "time_ns"
        case level
        case headroomOK = "headroom_ok"
        case headroomMiB = "headroom_mib"
        case reserveMiB = "reserve_mib"
        case roomMiB = "room_mib"
        case liveHolds = "live_holds"
        case jobs
    }

    public init(
        timeNS: Int64, level: String, headroomOK: Bool, headroomMiB: Int64, reserveMiB: Int64,
        roomMiB: Int64, liveHolds: Int64, jobs: [Job]
    ) {
        (self.timeNS, self.level, self.headroomOK, self.headroomMiB) = (timeNS, level, headroomOK, headroomMiB)
        (self.reserveMiB, self.roomMiB, self.liveHolds, self.jobs) = (reserveMiB, roomMiB, liveHolds, jobs)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.checkSchema(.v)
        timeNS = try c.decode(.timeNS, in: Clamp.time)
        level = try c.decode(String.self, forKey: .level)
        headroomOK = try c.decode(Bool.self, forKey: .headroomOK)
        headroomMiB = try c.decode(.headroomMiB, in: Clamp.signed)
        reserveMiB = try c.decode(.reserveMiB, in: Clamp.amount)
        roomMiB = try c.decode(.roomMiB, in: Clamp.signed)
        liveHolds = try c.decode(.liveHolds, in: Clamp.amount)
        jobs = try c.decodeIfPresent([Job].self, forKey: .jobs) ?? []
    }

    public init?(line: Data) {
        guard let s = try? JSONDecoder().decode(Self.self, from: line) else { return nil }
        self = s
    }
}

/// One line of a run in `events.jsonl`; the machine-wide lines, which name no run, are not.
public struct EventLine: Decodable, Sendable, Equatable {
    public let run: String
    public let attempt: Int64
    public let n: Int64
    public let timeNS: Int64
    public let label: String
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        case enqueue(Enqueue)
        case waiting(Waiting)
        case admitted(waitedS: Double)
        case ended(Ended)
        case stopped, cancelled, interrupted, refused, timeout
        case notStarted
        case outside(kind: String)
        /// An event this app does not use, by its name.
        case other(String)
    }

    public struct Enqueue: Decodable, Sendable, Equatable {
        public let ticket: String
        public let typicalS: Int64
        public let realMemory: Bool
        public let needMiB: Int64
        public let memMiB: Int64

        enum CodingKeys: String, CodingKey {
            case ticket
            case typicalS = "typical_s"
            case realMemory = "real_memory"
            case needMiB = "need_mib"
            case memMiB = "mem_mib"
        }
    }

    public struct Waiting: Decodable, Sendable, Equatable {
        public let reason: String
        public let noPass: String?
        /// The ticket examined ahead of it; absent for the head.
        public let ahead: String?
        /// Absent when the waiter's snapshot failed.
        public let roomMiB: Int64?

        enum CodingKeys: String, CodingKey {
            case reason
            case noPass = "no_pass"
            case ahead
            case roomMiB = "room_mib"
        }

        public init(reason: String, noPass: String? = nil, ahead: String? = nil, roomMiB: Int64? = nil) {
            (self.reason, self.noPass, self.ahead, self.roomMiB) = (reason, noPass, ahead, roomMiB)
        }
    }

    public struct Ended: Decodable, Sendable, Equatable {
        public let failOpen: String?
        public let stoppedBy: String?
        public let signal: String?

        enum CodingKeys: String, CodingKey {
            case failOpen = "fail_open"
            case stoppedBy = "stopped_by"
            case signal
        }
    }

    enum CodingKeys: String, CodingKey {
        case v, e, run, attempt, n, label, kind
        case timeNS = "time_ns"
        case waitedS = "waited_s"
    }

    public init(run: String, attempt: Int64, n: Int64, timeNS: Int64, label: String, kind: Kind) {
        (self.run, self.attempt, self.n, self.timeNS, self.label, self.kind) = (run, attempt, n, timeNS, label, kind)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.checkSchema(.v)
        run = try c.decode(String.self, forKey: .run)
        attempt = try c.decode(.attempt, in: Clamp.amount)
        n = try c.decode(.n, in: Clamp.amount)
        timeNS = try c.decode(.timeNS, in: Clamp.time)
        label = try c.decode(String.self, forKey: .label)
        switch try c.decode(String.self, forKey: .e) {
        case "enqueue": kind = .enqueue(try Enqueue(from: decoder))
        case "waiting": kind = .waiting(try Waiting(from: decoder))
        case "admitted": kind = .admitted(waitedS: try c.decode(Double.self, forKey: .waitedS))
        case "ended": kind = .ended(try Ended(from: decoder))
        case "stopped": kind = .stopped
        case "cancelled": kind = .cancelled
        case "interrupted": kind = .interrupted
        case "refused": kind = .refused
        case "timeout": kind = .timeout
        case "not_started": kind = .notStarted
        case "outside": kind = .outside(kind: try c.decode(String.self, forKey: .kind))
        case let e: kind = .other(e)
        }
    }

    public init?(line: Data) {
        guard let e = try? JSONDecoder().decode(Self.self, from: line) else { return nil }
        self = e
    }
}

/// The machine-wide `memory` line of `events.jsonl`: the largest processes, by name.
public struct MemoryLine: Decodable, Sendable, Equatable {
    public let timeNS: Int64
    public let top: [Process]
    /// The Docker VM's largest process; absent when none runs.
    public let vm: Process?

    public struct Process: Decodable, Sendable, Equatable {
        public let name: String
        public let footprintMiB: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case footprintMiB = "footprint_mib"
        }
    }

    enum CodingKeys: String, CodingKey {
        case v, e, top, vm
        case timeNS = "time_ns"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.checkSchema(.v)
        guard try c.decode(String.self, forKey: .e) == "memory" else {
            throw DecodingError.dataCorruptedError(forKey: .e, in: c, debugDescription: "not a memory line")
        }
        timeNS = try c.decode(.timeNS, in: Clamp.time)
        top = try c.decodeIfPresent([Process].self, forKey: .top) ?? []
        vm = try c.decodeIfPresent(Process.self, forKey: .vm)
    }

    public init?(line: Data) {
        guard let m = try? JSONDecoder().decode(Self.self, from: line) else { return nil }
        self = m
    }
}

extension SampleLine.Job {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (hold, label) = (try c.decode(String.self, forKey: .hold), try c.decode(String.self, forKey: .label))
        footprintMiB = try c.decode(.footprintMiB, in: Clamp.amount)
    }
}

extension EventLine.Enqueue {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (ticket, realMemory) = (try c.decode(String.self, forKey: .ticket), try c.decode(Bool.self, forKey: .realMemory))
        typicalS = try c.decode(.typicalS, in: Clamp.amount)
        (needMiB, memMiB) = (try c.decode(.needMiB, in: Clamp.amount), try c.decode(.memMiB, in: Clamp.amount))
    }
}

extension EventLine.Waiting {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            reason: try c.decode(String.self, forKey: .reason), noPass: try c.decodeIfPresent(String.self, forKey: .noPass),
            ahead: try c.decodeIfPresent(String.self, forKey: .ahead), roomMiB: try c.decodeIfPresent(.roomMiB, in: Clamp.signed))
    }
}

extension MemoryLine.Process {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (name, footprintMiB) = (try c.decode(String.self, forKey: .name), try c.decode(.footprintMiB, in: Clamp.amount))
    }
}

/// The ranges every integer read from the state directory, and every integer of `status` that
/// feeds arithmetic, is clamped into as it is decoded: no sum or difference the kit takes of them
/// can overflow. Seconds given as numbers are clamped by `seconds`.
enum Clamp {
    /// Sizes in MiB or KiB, counts and whole seconds.
    static let amount: ClosedRange<Int64> = 0...(1 << 40)
    /// A room or a headroom, which can be below 0, and an exit status.
    static let signed: ClosedRange<Int64> = -(1 << 40)...(1 << 40)
    /// Nanoseconds since the epoch, to the year 2116.
    static let time: ClosedRange<Int64> = 0...(1 << 62)

    /// Seconds in `0...(1 << 40)`, finite; a NaN is 0.
    static func seconds(_ s: Double) -> Double { s.isNaN ? 0 : min(max(s, 0), Double(amount.upperBound)) }
}

extension KeyedDecodingContainer {
    func decode(_ key: Key, in range: ClosedRange<Int64>) throws -> Int64 {
        min(max(try decode(Int64.self, forKey: key), range.lowerBound), range.upperBound)
    }

    func decodeIfPresent(_ key: Key, in range: ClosedRange<Int64>) throws -> Int64? {
        try decodeIfPresent(Int64.self, forKey: key).map { min(max($0, range.lowerBound), range.upperBound) }
    }

    func decodeSeconds(_ key: Key) throws -> Double { Clamp.seconds(try decode(Double.self, forKey: key)) }
}

/// Thrown for a document or line of a schema other than 1: its keys may mean something else.
struct OtherSchema: Error {
    let schema: Int64
}

extension KeyedDecodingContainer {
    func checkSchema(_ key: Key) throws {
        let schema = try decode(Int64.self, forKey: key)
        guard schema == 1 else { throw OtherSchema(schema: schema) }
    }
}
