import Foundation

/// Something the header says about a document that was read.
public enum Notice: Equatable, Sendable {
    case tooOld(Version), development, degraded(String), formatNotUnderstood, configError(String), schema(Int64)
}

/// Why there is no document to show.
public enum Problem: Equatable, Sendable {
    case notFound, stateUnreadable, failed(exitCode: Int32), malformed, timedOut
}

public enum StatusReading: Sendable, Equatable {
    case document(StatusDocument, [Notice])
    case problem(Problem)
}

/// What one run of `coreslot status --json` says. A stdout that decodes is a document whatever
/// the exit code: `status` prints its document and then exits 3 when runs fail open. A document
/// of another schema, or one from a coreslot too old to decode, is schema-only: notices alone.
public func interpret(_ r: RunResult, binary: CoreslotBinary) -> StatusReading {
    if r.timedOut { return .problem(.timedOut) }
    guard let code = r.exitCode else { return .problem(.notFound) }
    if r.stdout.contains(where: { !$0.isWhitespace }) {
        let only = { (schema: Int64) in StatusReading.document(.schemaOnly(schema), notices(.schemaOnly(schema), binary)) }
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: r.stdout), probe.schema != 1 {
            return only(probe.schema)
        }
        if let doc = try? StatusDocument.decode(r.stdout) { return .document(doc, notices(doc, binary)) }
        if !binary.version.isDevelopment, binary.version < .minimum { return only(1) }
        return .problem(.malformed)
    }
    if code == 3 { return .problem(.stateUnreadable) }
    return .problem(.failed(exitCode: code))
}

private struct SchemaProbe: Decodable { let schema: Int64 }

private func notices(_ doc: StatusDocument, _ binary: CoreslotBinary) -> [Notice] {
    var n: [Notice] = []
    if binary.version.isDevelopment {
        n.append(.development)
    } else if binary.version < .minimum {
        n.append(.tooOld(binary.version))
    }
    if doc.schema != 1 { n.append(.schema(doc.schema)) }
    if let d = doc.degraded { n.append(.degraded(d.reason)) }
    if !doc.formatUnderstood { n.append(.formatNotUnderstood) }
    if !doc.configError.isEmpty { n.append(.configError(doc.configError)) }
    return n
}

extension StatusDocument {
    /// A document carried for its schema and the notices alone: nothing else in it was read.
    static func schemaOnly(_ schema: Int64) -> StatusDocument {
        StatusDocument(
            schema: schema, stateDir: "", stateDirExists: false, format: 0, formatPresent: false,
            formatUnderstood: true, formatError: "", gen: 0, reconciledNS: 0, configError: "", degraded: nil,
            section: Section(held: false, holder: nil), mem: nil,
            watch: Watch(level: "", excessPoints: 0, protecting: false, reason: "", nextVictim: "", learning: 0),
            holds: [], tickets: [], deadHolds: [], cancelRequests: [], ignored: [:], observedS: 0, isSchemaOnly: true)
    }
}

private extension UInt8 {
    var isWhitespace: Bool { self == 0x20 || self == 0x0a || self == 0x0d || self == 0x09 }
}

/// Polls `coreslot status --json` and hands every reading to each subscriber. One run at a time.
public actor StatusSource {
    /// How long one `status` may take before it is stopped.
    static let statusTimeout: Duration = .seconds(5)

    private let binary: CoreslotBinary
    private let environment: [String: String]?
    private let runner: Runner
    private var interval: Duration = .seconds(10)
    private var subscribers: [UUID: AsyncStream<StatusReading>.Continuation] = [:]
    private var latest: StatusReading?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var wanted = false

    public init(binary: CoreslotBinary, environment: [String: String]?, runner: Runner = .process) {
        (self.binary, self.environment, self.runner) = (binary, environment, runner)
    }

    /// Every reading from now on, the latest one first; polling runs while anyone listens.
    public func readings() -> AsyncStream<StatusReading> {
        let (stream, continuation) = AsyncStream.makeStream(of: StatusReading.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        if let latest { continuation.yield(latest) }
        if loop == nil { loop = Task { await self.poll() } }
        return stream
    }

    /// 2 s while the popover or the window is visible, 10 s otherwise.
    public func setInterval(_ d: Duration) {
        interval = d
        sleeper?.cancel()
    }

    /// A reading at once; while one is in flight, the next starts as soon as it ends.
    public func readNow() {
        wanted = true
        sleeper?.cancel()
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        if subscribers.isEmpty { sleeper?.cancel() }
    }

    /// The one loop: it ends, and clears `loop`, only between runs and only with nobody listening.
    private func poll() async {
        while !subscribers.isEmpty {
            let started = ContinuousClock.now
            wanted = false
            let r = await runner.run(binary.url, ["status", "--json"], environment: environment, timeout: Self.statusTimeout)
            let reading = interpret(r, binary: binary)
            latest = reading
            for c in subscribers.values { c.yield(reading) }
            while !wanted && !subscribers.isEmpty && ContinuousClock.now < started + interval {
                let due = started + interval
                let s = Task { _ = try? await Task.sleep(until: due) }
                sleeper = s
                await s.value
                sleeper = nil
            }
        }
        loop = nil
    }
}
