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

/// One reading and the `coreslot` it came from; no `coreslot` when none was found.
public struct Polled: Sendable, Equatable {
    public let binary: CoreslotBinary?
    public let reading: StatusReading
}

/// Polls `coreslot status --json` for one consumer, one run at a time. A reading is taken when the
/// consumer asks for the next, so its loop is the only one, and polling ends when it stops asking.
/// Each poll looks for `coreslot` again, and reads its version again when the file found is another.
public actor StatusSource {
    /// How long one `status` may take before it is stopped.
    static let statusTimeout: Duration = .seconds(5)

    /// 2 s while the popover or the window is visible, 10 s otherwise.
    public static func interval(visible: Bool) -> Duration { visible ? .seconds(2) : .seconds(10) }

    private let find: @Sendable () -> URL?
    private let environment: [String: String]?
    private let runner: Runner
    private var known: CoreslotBinary?
    private var interval = interval(visible: false)
    private var started: ContinuousClock.Instant?
    private var sleeper: Task<Void, Never>?
    private var wanted = false

    /// `find`: where `coreslot` is now, nil when nowhere.
    public init(find: @escaping @Sendable () -> URL?, environment: [String: String]?, runner: Runner = .process) {
        (self.find, self.environment, self.runner) = (find, environment, runner)
    }

    /// The readings, each taken when it is asked for; the first at once.
    public nonisolated func readings() -> AsyncStream<Polled> { AsyncStream(unfolding: { await self.next() }) }

    public func setInterval(_ d: Duration) {
        interval = d
        sleeper?.cancel()
    }

    /// A reading at once; while one is in flight, the next starts as soon as it ends.
    public func readNow() {
        wanted = true
        sleeper?.cancel()
    }

    /// The next reading, an interval after the last one started; nil once the consumer is cancelled.
    private func next() async -> Polled? {
        while let s = started, !wanted, !Task.isCancelled, ContinuousClock.now < s + interval {
            let nap = Task { [due = s + interval] in _ = try? await Task.sleep(until: due) }
            sleeper = nap
            await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
            sleeper = nil
        }
        if Task.isCancelled { return nil }
        (started, wanted) = (ContinuousClock.now, false)
        return await read()
    }

    /// One reading: the `coreslot` found now, then its `status --json`.
    public func read() async -> Polled {
        guard let binary = await locate() else { return Polled(binary: nil, reading: .problem(.notFound)) }
        let r = await runner.run(binary.url, ["status", "--json"], environment: environment, timeout: Self.statusTimeout)
        return Polled(binary: binary, reading: interpret(r, binary: binary))
    }

    /// The `coreslot` found now, none when it cannot be read; its version is read again only for
    /// another path, or a file there replaced or changed.
    private func locate() async -> CoreslotBinary? {
        guard let url = find(), let id = Self.identity(url) else { known = nil; return nil }
        if let k = known, k.url == url, k.identity == id { return k }
        known = await CoreslotBinary.probe(url, environment: environment, runner: runner)
        known?.identity = id
        return known
    }

    /// The file's device, inode, modification time and size, symlinks followed: a file overwritten
    /// in place keeps its device and inode.
    static func identity(_ url: URL) -> [Int64]? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return [Int64(st.st_dev), Int64(bitPattern: st.st_ino), Int64(st.st_mtimespec.tv_sec), Int64(st.st_mtimespec.tv_nsec), st.st_size]
    }
}
