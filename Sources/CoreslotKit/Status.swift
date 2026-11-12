import Foundation

/// The document `coreslot status --json` prints, schema 1, as
/// https://github.com/core-slot/coreslot/blob/v0.8.0/docs/status-json.md lists it.
///
/// A key the reference allows to be null or absent is optional, and so is every key coreslot 0.8.0
/// added, so a 0.7.0 document decodes too. Unknown keys are ignored.
public struct StatusDocument: Decodable, Sendable, Equatable {
    public let schema: Int64
    public let stateDir: String
    public let stateDirExists: Bool
    public let format: Int64
    public let formatPresent: Bool
    public let formatUnderstood: Bool
    public let formatError: String
    public let gen: Int64
    public let reconciledNS: Int64
    public let configError: String
    public let degraded: Degraded?
    public let section: Section
    public let mem: Mem?
    public let watch: Watch
    public let holds: [Hold]
    public let tickets: [Ticket]
    public let deadHolds: [String]
    public let cancelRequests: [String]
    public let ignored: [String: Int64]
    public let observedS: Double
    /// True for a document of another schema or of a coreslot too old to decode: only its notices
    /// are shown, and its other keys, which are invented, are not read.
    public internal(set) var isSchemaOnly = false

    enum CodingKeys: String, CodingKey {
        case schema
        case stateDir = "state_dir"
        case stateDirExists = "state_dir_exists"
        case format
        case formatPresent = "format_present"
        case formatUnderstood = "format_understood"
        case formatError = "format_error"
        case gen
        case reconciledNS = "reconciled_ns"
        case configError = "config_error"
        case degraded, section, mem, watch, holds, tickets
        case deadHolds = "dead_holds"
        case cancelRequests = "cancel_requests"
        case ignored
        case observedS = "observed_s"
    }

    public struct Degraded: Decodable, Sendable, Equatable {
        public let reason: String
        public let firstNS: Int64
        public let count: Int64
        public let malformed: Bool

        enum CodingKeys: String, CodingKey {
            case reason
            case firstNS = "first_ns"
            case count, malformed
        }
    }

    public struct Section: Decodable, Sendable, Equatable {
        public let held: Bool
        public let holder: Holder?

        public struct Holder: Decodable, Sendable, Equatable {
            public let pid: Int64
            public let enteredNS: Int64
            public let heldForS: Double
            public let alive: Bool?

            enum CodingKeys: String, CodingKey {
                case pid
                case enteredNS = "entered_ns"
                case heldForS = "held_for_s"
                case alive
            }
        }
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
        public let excessPoints: Double
        public let protecting: Bool
        public let reason: String
        public let nextVictim: String
        public let learning: Int64

        enum CodingKeys: String, CodingKey {
            case level
            case excessPoints = "excess_points"
            case protecting, reason
            case nextVictim = "next_victim"
            case learning
        }
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
        public let ownerExited: Bool
        /// Present and true for container work only.
        public let container: Bool?
        /// Present once the hold's tree has used next to no CPU for 30 minutes.
        public let noCPUS: Int64?
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
            case stops
            case ownerExited = "owner_exited"
            case container
            case noCPUS = "no_cpu_s"
            case typicalS = "typical_s"
            case leftS = "left_s"
            case stoppable
        }
    }

    public struct Ticket: Decodable, Sendable, Equatable {
        public let name: String?
        public let id: String
        public let label: String
        public let pid: Int64
        public let needMiB: Int64
        public let createdNS: Int64
        public let waitedS: Double
        public let position: Int64
        public let state: String
        public let stalled: Bool?
        public let expectedWaitS: Int64?

        enum CodingKeys: String, CodingKey {
            case name, id, label, pid
            case needMiB = "need_mib"
            case createdNS = "created_ns"
            case waitedS = "waited_s"
            case position, state, stalled
            case expectedWaitS = "expected_wait_s"
        }
    }

    public static func decode(_ data: Data) throws -> StatusDocument {
        try JSONDecoder().decode(StatusDocument.self, from: data)
    }
}
