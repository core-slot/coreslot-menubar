import Foundation

/// The document `coreslot status --json` prints, schema 1, as
/// https://github.com/core-slot/coreslot/blob/v0.8.0/docs/status-json.md lists it.
///
/// A key the reference allows to be null or absent is optional, and so is every key coreslot 0.8.0
/// added, so a 0.7.0 document decodes too. Unknown keys are ignored. The integers of `mem`, the
/// holds and the tickets that feed arithmetic, and every number of seconds, are clamped by `Clamp`.
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

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                (pid, enteredNS) = (try c.decode(Int64.self, forKey: .pid), try c.decode(Int64.self, forKey: .enteredNS))
                (heldForS, alive) = (try c.decodeSeconds(.heldForS), try c.decodeIfPresent(Bool.self, forKey: .alive))
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

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (name, label, pid) = (try c.decode(String.self, forKey: .name), try c.decode(String.self, forKey: .label), try c.decode(Int64.self, forKey: .pid))
            (startNS, arrivalNS) = (try c.decode(.startNS, in: Clamp.time), try c.decode(.arrivalNS, in: Clamp.time))
            (heldForS, needMiB, footprintMiB) = (try c.decodeSeconds(.heldForS), try c.decode(.needMiB, in: Clamp.amount), try c.decode(.footprintMiB, in: Clamp.amount))
            (stops, ownerExited) = (try c.decode(Int64.self, forKey: .stops), try c.decode(Bool.self, forKey: .ownerExited))
            (container, noCPUS) = (try c.decodeIfPresent(Bool.self, forKey: .container), try c.decodeIfPresent(Int64.self, forKey: .noCPUS))
            (typicalS, leftS) = (try c.decodeIfPresent(.typicalS, in: Clamp.amount), try c.decodeIfPresent(.leftS, in: Clamp.amount))
            stoppable = try c.decodeIfPresent(Bool.self, forKey: .stoppable)
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

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (name, id, label) = (try c.decodeIfPresent(String.self, forKey: .name), try c.decode(String.self, forKey: .id), try c.decode(String.self, forKey: .label))
            (pid, needMiB) = (try c.decode(Int64.self, forKey: .pid), try c.decode(.needMiB, in: Clamp.amount))
            (createdNS, waitedS) = (try c.decode(.createdNS, in: Clamp.time), try c.decodeSeconds(.waitedS))
            (position, state) = (try c.decode(Int64.self, forKey: .position), try c.decode(String.self, forKey: .state))
            (stalled, expectedWaitS) = (try c.decodeIfPresent(Bool.self, forKey: .stalled), try c.decodeIfPresent(.expectedWaitS, in: Clamp.amount))
        }
    }

    /// Throws `OtherSchema` for a schema other than 1, whatever its other keys.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (schema, stateDir) = (try c.decode(Int64.self, forKey: .schema), try c.decode(String.self, forKey: .stateDir))
        (stateDirExists, format) = (try c.decode(Bool.self, forKey: .stateDirExists), try c.decode(Int64.self, forKey: .format))
        (formatPresent, formatUnderstood) = (try c.decode(Bool.self, forKey: .formatPresent), try c.decode(Bool.self, forKey: .formatUnderstood))
        (formatError, gen) = (try c.decode(String.self, forKey: .formatError), try c.decode(Int64.self, forKey: .gen))
        (reconciledNS, configError) = (try c.decode(Int64.self, forKey: .reconciledNS), try c.decode(String.self, forKey: .configError))
        (degraded, section) = (try c.decodeIfPresent(Degraded.self, forKey: .degraded), try c.decode(Section.self, forKey: .section))
        (mem, watch) = (try c.decodeIfPresent(Mem.self, forKey: .mem), try c.decode(Watch.self, forKey: .watch))
        (holds, tickets) = (try c.decode([Hold].self, forKey: .holds), try c.decode([Ticket].self, forKey: .tickets))
        (deadHolds, cancelRequests) = (try c.decode([String].self, forKey: .deadHolds), try c.decode([String].self, forKey: .cancelRequests))
        (ignored, observedS) = (try c.decode([String: Int64].self, forKey: .ignored), try c.decodeSeconds(.observedS))
    }

    public static func decode(_ data: Data) throws -> StatusDocument {
        _ = try JSONDecoder().decode(SchemaProbe.self, from: data)
        return try JSONDecoder().decode(StatusDocument.self, from: data)
    }

    private struct SchemaProbe: Decodable {
        init(from decoder: any Decoder) throws { try decoder.container(keyedBy: CodingKeys.self).checkSchema(.schema) }
    }
}
