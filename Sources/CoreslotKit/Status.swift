import Foundation

/// The document `coreslot status --json` prints, schema 1, as
/// https://github.com/core-slot/coreslot/blob/v0.8.0/docs/status-json.md lists it.
///
/// Only the keys the app reads are decoded; the others are ignored, as unknown keys are. A key the
/// reference allows to be null or absent is optional, and so is every key coreslot 0.8.0 added, so
/// a 0.7.0 document decodes too. The integers of `mem`, the
/// holds and the tickets that feed arithmetic, and every number of seconds, are clamped by `Clamp`.
package struct StatusDocument: Decodable, Sendable, Equatable {
    package let schema: Int64
    package let stateDir: String
    package let formatUnderstood: Bool
    package let formatError: String
    package let configError: String
    package let degraded: Degraded?
    package let mem: Mem?
    package let watch: Watch
    package let holds: [Hold]
    package let tickets: [Ticket]
    /// The ids of the tickets with a cancel pending, by whoever asked; none when absent.
    package let cancelRequests: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case stateDir = "state_dir"
        case formatUnderstood = "format_understood"
        case formatError = "format_error"
        case configError = "config_error"
        case degraded, mem, watch, holds, tickets
        case cancelRequests = "cancel_requests"
    }

    package struct Degraded: Decodable, Sendable, Equatable {
        package let reason: String
    }

    package struct Mem: Decodable, Sendable, Equatable {
        package let reservedMiB: Int64
        package let freeMiB: Int64
        package let machineMiB: Int64?
        package let reserveMiB: Int64?
        package let headroomMiB: Int64?
        package let roomMiB: Int64?

        enum CodingKeys: String, CodingKey {
            case reservedMiB = "reserved_mib"
            case freeMiB = "free_mib"
            case machineMiB = "machine_mib"
            case reserveMiB = "reserve_mib"
            case headroomMiB = "headroom_mib"
            case roomMiB = "room_mib"
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (reservedMiB, freeMiB) = (try c.decode(.reservedMiB, in: Clamp.amount), try c.decode(.freeMiB, in: Clamp.amount))
            machineMiB = try c.decodeIfPresent(.machineMiB, in: Clamp.amount)
            reserveMiB = try c.decodeIfPresent(.reserveMiB, in: Clamp.amount)
            headroomMiB = try c.decodeIfPresent(.headroomMiB, in: Clamp.signed)
            roomMiB = try c.decodeIfPresent(.roomMiB, in: Clamp.signed)
        }
    }

    package struct Watch: Decodable, Sendable, Equatable {
        package let level: String
        package let protecting: Bool
        package let reason: String
        package let learning: Int64
    }

    package struct Hold: Decodable, Sendable, Equatable {
        package let name: String
        package let label: String
        package let pid: Int64
        package let startNS: Int64
        package let heldForS: Double
        package let arrivalNS: Int64
        package let needMiB: Int64
        package let footprintMiB: Int64
        package let stops: Int64
        /// Present and true for container work only.
        package let container: Bool?
        package let typicalS: Int64?
        package let leftS: Int64?
        package let stoppable: Bool?

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

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (name, label, pid) = (try c.decode(String.self, forKey: .name), try c.decode(String.self, forKey: .label), try c.decode(Int64.self, forKey: .pid))
            (startNS, arrivalNS) = (try c.decode(.startNS, in: Clamp.time), try c.decode(.arrivalNS, in: Clamp.time))
            (heldForS, needMiB, footprintMiB) = (try c.decodeSeconds(.heldForS), try c.decode(.needMiB, in: Clamp.amount), try c.decode(.footprintMiB, in: Clamp.amount))
            (stops, container) = (try c.decode(Int64.self, forKey: .stops), try c.decodeIfPresent(Bool.self, forKey: .container))
            (typicalS, leftS) = (try c.decodeIfPresent(.typicalS, in: Clamp.amount), try c.decodeIfPresent(.leftS, in: Clamp.amount))
            stoppable = try c.decodeIfPresent(Bool.self, forKey: .stoppable)
        }
    }

    package struct Ticket: Decodable, Sendable, Equatable {
        package let name: String?
        package let id: String
        package let label: String
        package let needMiB: Int64
        package let createdNS: Int64
        package let waitedS: Double
        package let position: Int64
        package let state: String
        package let expectedWaitS: Int64?

        enum CodingKeys: String, CodingKey {
            case name, id, label
            case needMiB = "need_mib"
            case createdNS = "created_ns"
            case waitedS = "waited_s"
            case position, state
            case expectedWaitS = "expected_wait_s"
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (name, id, label) = (try c.decodeIfPresent(String.self, forKey: .name), try c.decode(String.self, forKey: .id), try c.decode(String.self, forKey: .label))
            (needMiB, createdNS) = (try c.decode(.needMiB, in: Clamp.amount), try c.decode(.createdNS, in: Clamp.time))
            (waitedS, position) = (try c.decodeSeconds(.waitedS), try c.decode(Int64.self, forKey: .position))
            (state, expectedWaitS) = (try c.decode(String.self, forKey: .state), try c.decodeIfPresent(.expectedWaitS, in: Clamp.amount))
        }

        /// Waiting or stalled: in the queue, where a dead ticket only awaits reconciliation.
        package var live: Bool { state != "dead" }
    }

    /// Decodes the keys whatever `schema` says; `decode(_:)` is what checks the schema first.
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (schema, stateDir) = (try c.decode(Int64.self, forKey: .schema), try c.decode(String.self, forKey: .stateDir))
        (formatUnderstood, formatError) = (try c.decode(Bool.self, forKey: .formatUnderstood), try c.decode(String.self, forKey: .formatError))
        (configError, degraded) = (try c.decode(String.self, forKey: .configError), try c.decodeIfPresent(Degraded.self, forKey: .degraded))
        (mem, watch) = (try c.decodeIfPresent(Mem.self, forKey: .mem), try c.decode(Watch.self, forKey: .watch))
        (holds, tickets) = (try c.decode([Hold].self, forKey: .holds), try c.decode([Ticket].self, forKey: .tickets))
        cancelRequests = try c.decodeIfPresent([String].self, forKey: .cancelRequests) ?? []
    }

    /// Throws `OtherSchema` for a schema other than 1, whatever its other keys.
    package static func decode(_ data: Data) throws -> StatusDocument {
        _ = try JSONDecoder().decode(SchemaProbe.self, from: data)
        return try JSONDecoder().decode(StatusDocument.self, from: data)
    }

    private struct SchemaProbe: Decodable {
        init(from decoder: any Decoder) throws { try decoder.container(keyedBy: CodingKeys.self).checkSchema(.schema) }
    }
}
