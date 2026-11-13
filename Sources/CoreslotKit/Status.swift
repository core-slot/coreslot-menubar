import Foundation

/// The document `coreslot status --json` prints, schema 1, as
/// https://github.com/core-slot/coreslot/blob/v0.8.0/docs/status-json.md lists it.
///
/// Only the keys the app reads are decoded; the others are ignored, as unknown keys are. A key the
/// reference allows to be null or absent is optional, and so is every key coreslot 0.8.0 added, so
/// a 0.7.0 document decodes too. The integers of `mem`, the
/// holds and the tickets that feed arithmetic, and every number of seconds, are clamped by `Clamp`.
public struct StatusDocument: Decodable, Sendable, Equatable {
    public let schema: Int64
    public let stateDir: String
    public let formatUnderstood: Bool
    public let formatError: String
    public let configError: String
    public let degraded: Degraded?
    public let mem: Mem?
    public let watch: Watch
    public let holds: [Hold]
    public let tickets: [Ticket]
    /// The ids of the tickets with a cancel pending, by whoever asked; none when absent.
    public let cancelRequests: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case stateDir = "state_dir"
        case formatUnderstood = "format_understood"
        case formatError = "format_error"
        case configError = "config_error"
        case degraded, mem, watch, holds, tickets
        case cancelRequests = "cancel_requests"
    }

    public struct Degraded: Decodable, Sendable, Equatable {
        public let reason: String
    }

    public struct Mem: Decodable, Sendable, Equatable {
        public let reservedMiB: Int64
        public let freeMiB: Int64
        public let machineMiB: Int64?
        public let reserveMiB: Int64?
        public let headroomMiB: Int64?
        public let roomMiB: Int64?

        enum CodingKeys: String, CodingKey {
            case reservedMiB = "reserved_mib"
            case freeMiB = "free_mib"
            case machineMiB = "machine_mib"
            case reserveMiB = "reserve_mib"
            case headroomMiB = "headroom_mib"
            case roomMiB = "room_mib"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (reservedMiB, freeMiB) = (try c.decode(.reservedMiB, in: Clamp.amount), try c.decode(.freeMiB, in: Clamp.amount))
            machineMiB = try c.decodeIfPresent(.machineMiB, in: Clamp.amount)
            reserveMiB = try c.decodeIfPresent(.reserveMiB, in: Clamp.amount)
            headroomMiB = try c.decodeIfPresent(.headroomMiB, in: Clamp.signed)
            roomMiB = try c.decodeIfPresent(.roomMiB, in: Clamp.signed)
        }
    }

    public struct Watch: Decodable, Sendable, Equatable {
        public let level: String
        public let protecting: Bool
        public let reason: String
        public let learning: Int64
    }

    public struct Hold: Decodable, Sendable, Equatable {
        public let name: String
        public let label: String
        public let pid: Int64
        public let startNS: Int64
        public let heldForS: Double
        public let arrivalNS: Int64
        public let needMiB: Int64
        public let footprintMiB: Int64
        public let stops: Int64
        /// Present and true for container work only.
        public let container: Bool?
        public let typicalS: Int64?
        public let leftS: Int64?
        public let stoppable: Bool?

        enum CodingKeys: String, CodingKey {
            case name, label, pid
            case startNS = "start_ns"
            case heldForS = "held_for_s"
            case arrivalNS = "arrival_ns"
            case needMiB = "need_mib"
            case footprintMiB = "footprint_mib"
            case stops, container
            case typicalS = "typical_s"
            case leftS = "left_s"
            case stoppable
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (name, label, pid) = (try c.decode(String.self, forKey: .name), try c.decode(String.self, forKey: .label), try c.decode(Int64.self, forKey: .pid))
            (startNS, arrivalNS) = (try c.decode(.startNS, in: Clamp.time), try c.decode(.arrivalNS, in: Clamp.time))
            (heldForS, needMiB, footprintMiB) = (try c.decodeSeconds(.heldForS), try c.decode(.needMiB, in: Clamp.amount), try c.decode(.footprintMiB, in: Clamp.amount))
            (stops, container) = (try c.decode(Int64.self, forKey: .stops), try c.decodeIfPresent(Bool.self, forKey: .container))
            (typicalS, leftS) = (try c.decodeIfPresent(.typicalS, in: Clamp.amount), try c.decodeIfPresent(.leftS, in: Clamp.amount))
            stoppable = try c.decodeIfPresent(Bool.self, forKey: .stoppable)
        }
    }

    public struct Ticket: Decodable, Sendable, Equatable {
        public let name: String?
        public let id: String
        public let label: String
        public let needMiB: Int64
        public let createdNS: Int64
        public let waitedS: Double
        public let position: Int64
        public let state: String
        public let expectedWaitS: Int64?

        enum CodingKeys: String, CodingKey {
            case name, id, label
            case needMiB = "need_mib"
            case createdNS = "created_ns"
            case waitedS = "waited_s"
            case position, state
            case expectedWaitS = "expected_wait_s"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (name, id, label) = (try c.decodeIfPresent(String.self, forKey: .name), try c.decode(String.self, forKey: .id), try c.decode(String.self, forKey: .label))
            (needMiB, createdNS) = (try c.decode(.needMiB, in: Clamp.amount), try c.decode(.createdNS, in: Clamp.time))
            (waitedS, position) = (try c.decodeSeconds(.waitedS), try c.decode(Int64.self, forKey: .position))
            (state, expectedWaitS) = (try c.decode(String.self, forKey: .state), try c.decodeIfPresent(.expectedWaitS, in: Clamp.amount))
        }

        /// Waiting or stalled: in the queue, where a dead ticket only awaits reconciliation.
        public var live: Bool { state != "dead" }
    }

    /// Decodes the keys whatever `schema` says; `decode(_:)` is what checks the schema first.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (schema, stateDir) = (try c.decode(Int64.self, forKey: .schema), try c.decode(String.self, forKey: .stateDir))
        (formatUnderstood, formatError) = (try c.decode(Bool.self, forKey: .formatUnderstood), try c.decode(String.self, forKey: .formatError))
        (configError, degraded) = (try c.decode(String.self, forKey: .configError), try c.decodeIfPresent(Degraded.self, forKey: .degraded))
        (mem, watch) = (try c.decodeIfPresent(Mem.self, forKey: .mem), try c.decode(Watch.self, forKey: .watch))
        (holds, tickets) = (try c.decode([Hold].self, forKey: .holds), try c.decode([Ticket].self, forKey: .tickets))
        cancelRequests = try c.decodeIfPresent([String].self, forKey: .cancelRequests) ?? []
    }

    /// Throws `OtherSchema` for a schema other than 1, whatever its other keys.
    public static func decode(_ data: Data) throws -> StatusDocument {
        _ = try JSONDecoder().decode(SchemaProbe.self, from: data)
        return try JSONDecoder().decode(StatusDocument.self, from: data)
    }

    private struct SchemaProbe: Decodable {
        init(from decoder: any Decoder) throws { try decoder.container(keyedBy: CodingKeys.self).checkSchema(.schema) }
    }
}
