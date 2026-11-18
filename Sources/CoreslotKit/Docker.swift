import Foundation

/// The `docker` object of `coreslot status --json --docker`, as
/// https://github.com/core-slot/coreslot/blob/main/docs/status-json.md lists it, with the
/// document's `config_warnings`. Every key of the object is always present; the sizes are clamped.
package struct DockerStatus: Sendable, Equatable {
    package struct VM: Decodable, Sendable, Equatable {
        package let memMiB: Int64?
        package let identified: Bool
        /// The VM process's footprint; nil unless `identified`.
        package let footprintMiB: Int64?

        enum CodingKeys: String, CodingKey {
            case memMiB = "mem_mib", identified, footprintMiB = "footprint_mib"
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (memMiB, footprintMiB) = (try c.decodeIfPresent(.memMiB, in: Clamp.amount), try c.decodeIfPresent(.footprintMiB, in: Clamp.amount))
            identified = try c.decode(Bool.self, forKey: .identified)
        }
    }

    package struct Container: Decodable, Sendable, Equatable {
        package let id: String
        package let name: String
        package let image: String
        /// Its Compose project; empty when it has none.
        package let project: String
        package let usageMiB: Int64
        package let limitMiB: Int64

        enum CodingKeys: String, CodingKey {
            case id, name, image, project, usageMiB = "usage_mib", limitMiB = "limit_mib"
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (id, name) = (try c.decode(String.self, forKey: .id), try c.decode(String.self, forKey: .name))
            (image, project) = (try c.decode(String.self, forKey: .image), try c.decode(String.self, forKey: .project))
            (usageMiB, limitMiB) = (try c.decode(.usageMiB, in: Clamp.amount), try c.decode(.limitMiB, in: Clamp.amount))
        }
    }

    /// `ok`, `off`, `not_running`, `other_engine` or `no_reading`; another word is a newer coreslot's.
    package let state: String
    package let reason: String
    package let vm: VM
    package let freeEstMiB: Int64?
    package let containers: [Container]
    package let warnings: [String]
}

/// What one run of `coreslot status --json --docker` says.
package enum DockerReading: Sendable, Equatable {
    case section(DockerStatus)
    /// A coreslot that does not know `--docker`: its usage error, exit 64 with nothing on stdout
    /// (the usage goes to stderr, which the app does not keep; the app passes no other argument
    /// `status` could refuse), or a document without a `docker` object. The section is not drawn.
    case unsupported
    case problem(Problem)
}

private struct DockerDocument: Decodable {
    let docker: Wrapped?
    let warnings: [String]

    struct Wrapped: Decodable {
        let state: String
        let reason: String
        let vm: DockerStatus.VM
        let freeEstMiB: Int64?
        let containers: [DockerStatus.Container]

        enum CodingKeys: String, CodingKey { case state, reason, vm, freeEstMiB = "free_est_mib", containers }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (state, reason) = (try c.decode(String.self, forKey: .state), try c.decode(String.self, forKey: .reason))
            (vm, containers) = (try c.decode(DockerStatus.VM.self, forKey: .vm), try c.decode([DockerStatus.Container].self, forKey: .containers))
            freeEstMiB = try c.decodeIfPresent(.freeEstMiB, in: Clamp.amount)
        }
    }

    enum CodingKeys: String, CodingKey { case schema, docker, warnings = "config_warnings" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.checkSchema(.schema)
        docker = try c.decodeIfPresent(Wrapped.self, forKey: .docker)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

/// A stdout that decodes is a reading whatever the exit code, as `interpret` takes a document.
package func interpretDocker(_ r: RunResult) -> DockerReading {
    if r.timedOut { return .problem(.timedOut) }
    guard let code = r.exitCode else { return .problem(.notFound) }
    guard r.stdout.contains(where: { $0 != 0x20 && $0 != 0x0a && $0 != 0x0d && $0 != 0x09 }) else {
        if code == 64 { return .unsupported }
        return .problem(code == 3 ? .stateUnreadable : .failed(exitCode: code))
    }
    do {
        let doc = try JSONDecoder().decode(DockerDocument.self, from: r.stdout)
        guard let d = doc.docker else { return .unsupported }
        return .section(DockerStatus(state: d.state, reason: d.reason, vm: d.vm, freeEstMiB: d.freeEstMiB, containers: d.containers, warnings: doc.warnings))
    } catch {
        return .problem(.malformed)
    }
}

/// Reads `coreslot status --json --docker` for the popover, at most once in 30 s. The app runs `coreslot` alone: it needs no `docker` on its `PATH`, and the
/// socket is coreslot's to read.
package actor DockerSource {
    package static let every: TimeInterval = 30

    private let runner: Runner
    private var last: Date?
    /// The file of a `coreslot` that refused `--docker`: not asked again while it is the same file.
    private var refused: (url: URL, identity: [Int64])?

    package init(runner: Runner = .process) { self.runner = runner }

    /// The reading, or nil when not asked for now: one taken less than 30 s ago, or one in flight.
    /// The caller asks only while a surface is visible (`Store.ingest`). The time is noted before the run, so a slow run is not asked twice.
    package func read(_ binary: CoreslotBinary, at now: Date) async -> DockerReading? {
        let identity = StatusSource.identity(binary.url)
        if let r = refused, r.url == binary.url, r.identity == identity { return nil }
        guard last.map({ now.timeIntervalSince($0) >= Self.every }) ?? true else { return nil }
        last = now
        let reading = interpretDocker(await runner.run(binary.url, ["status", "--json", "--docker"], environment: nil, timeout: .seconds(10)))
        refused = reading == .unsupported ? identity.map { (binary.url, $0) } : nil
        return reading
    }
}
