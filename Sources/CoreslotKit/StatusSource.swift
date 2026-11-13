import Foundation

/// Something the header says about a reading.
public enum Notice: Equatable, Sendable {
    case tooOld, degraded(String), formatNotUnderstood(String), configError(String), schema(Int64)
}

/// Why there is no document to show.
public enum Problem: Equatable, Sendable {
    case notFound, stateUnreadable, failed(exitCode: Int32), malformed, timedOut
}

public enum StatusReading: Sendable, Equatable {
    case document(StatusDocument, [Notice])
    /// A document of another schema, or from a coreslot too old to decode: nothing in it is read.
    case notices([Notice])
    case problem(Problem)
}

/// What one run of `coreslot status --json` says. A stdout that decodes is a document whatever
/// the exit code: `status` prints its document and then exits 3 when runs fail open.
public func interpret(_ r: RunResult, binary: CoreslotBinary) -> StatusReading {
    if r.timedOut { return .problem(.timedOut) }
    guard let code = r.exitCode else { return .problem(.notFound) }
    guard r.stdout.contains(where: { !$0.isWhitespace }) else {
        return .problem(code == 3 ? .stateUnreadable : .failed(exitCode: code))
    }
    let old: [Notice] = !binary.version.isDevelopment && binary.version < .minimum ? [.tooOld] : []
    do {
        let doc = try StatusDocument.decode(r.stdout)
        return .document(doc, old + notices(doc))
    } catch let other as OtherSchema {
        return .notices(old + [.schema(other.schema)])
    } catch {
        return old.isEmpty ? .problem(.malformed) : .notices(old)
    }
}

private func notices(_ doc: StatusDocument) -> [Notice] {
    var n: [Notice] = []
    if let d = doc.degraded { n.append(.degraded(d.reason)) }
    if !doc.formatUnderstood { n.append(.formatNotUnderstood(doc.formatError)) }
    if !doc.configError.isEmpty { n.append(.configError(doc.configError)) }
    return n
}

private extension UInt8 {
    var isWhitespace: Bool { self == 0x20 || self == 0x0a || self == 0x0d || self == 0x09 }
}

/// Polls `coreslot status --json` and hands every reading to one stream. One run at a time.
public actor StatusSource {
    /// How long one `status` may take before it is stopped.
    static let statusTimeout: Duration = .seconds(5)

    private let binary: CoreslotBinary
    private let environment: [String: String]?
    private let runner: Runner
    private let stream: AsyncStream<StatusReading>
    private let output: AsyncStream<StatusReading>.Continuation
    private var interval: Duration = .seconds(10)
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var wanted = false
    private var consumed = true

    public init(binary: CoreslotBinary, environment: [String: String]?, runner: Runner = .process) {
        (self.binary, self.environment, self.runner) = (binary, environment, runner)
        (stream, output) = AsyncStream.makeStream(of: StatusReading.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// The one stream of readings, from the first call on; polling runs while it is consumed.
    public func readings() -> AsyncStream<StatusReading> {
        if loop == nil {
            output.onTermination = { _ in Task { await self.ended() } }
            loop = Task { await self.poll() }
        }
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

    private func ended() {
        consumed = false
        sleeper?.cancel()
    }

    /// The one loop: it ends only between runs, once the stream is no longer consumed.
    private func poll() async {
        while consumed {
            let started = ContinuousClock.now
            wanted = false
            let r = await runner.run(binary.url, ["status", "--json"], environment: environment, timeout: Self.statusTimeout)
            output.yield(interpret(r, binary: binary))
            while !wanted && consumed && ContinuousClock.now < started + interval {
                let due = started + interval
                let s = Task { _ = try? await Task.sleep(until: due) }
                sleeper = s
                await s.value
                sleeper = nil
            }
        }
    }
}
