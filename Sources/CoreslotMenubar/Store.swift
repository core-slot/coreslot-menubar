import CoreslotKit
import Foundation
import Observation

/// The places that show the live view; while any is visible the view is at most 2 s behind.
enum Surface: Hashable { case popover, timeline }

/// Where readings come from: the `coreslot` found on this machine, or, in a debug build, a fixture.
struct Feed: Sendable {
    let locate: @Sendable () async -> CoreslotBinary?
    let runner: Runner
    /// Read the record here instead of at the document's `state_dir`.
    var stateDir: URL? = nil
    var clock: @Sendable () -> Date = { Date() }
    /// Fixtures only: the record's state as the variant names it, not as the app's clock finds it.
    var record: RecordState? = nil

    static let live = Feed(
        locate: {
            let path = ProcessInfo.processInfo.environment["PATH"]
            guard let url = Locate.find(override: nil, directories: Locate.standardDirectories, path: path)
            else { return nil }
            return await CoreslotBinary.probe(url, environment: nil)
        },
        runner: .process)
}

/// The one store the views lay out. `CoreslotKit` decides; this only keeps what it says.
@MainActor @Observable
final class Store {
    private(set) var reading: StatusReading?
    /// When `reading` was taken, by `feed.clock`.
    private(set) var readAt: Date?
    private(set) var binary: CoreslotBinary?
    private(set) var record = RecordSnapshot()
    private(set) var recordState: RecordState = .unknown
    private(set) var report: Report?
    /// Each label's colour, by order of first sight; a new label never repaints the others.
    private(set) var labelColors: [String: Int] = [:]

    @ObservationIgnored let feed: Feed
    @ObservationIgnored private let reader = RecordReader()
    @ObservationIgnored private var source: StatusSource?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var visible: Set<Surface> = []
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var holdLiveSince: Date?
    @ObservationIgnored private var reportAt: Date?
    @ObservationIgnored private var reportTask: Task<Void, Never>?

    init(feed: Feed) { self.feed = feed }

    var now: Date { feed.clock() }

    var icon: IconState { reading.map(IconState.init) ?? .idle }

    /// The document, unless it is schema-only: another schema, or too old a coreslot to decode,
    /// whose `state_dir`, `watch` and `mem` are invented and feed nothing.
    var document: StatusDocument? {
        guard case .document(let doc, _) = reading, !doc.isSchemaOnly else { return nil }
        return doc
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    func setVisible(_ surface: Surface, _ on: Bool) {
        if on { visible.insert(surface) } else { visible.remove(surface) }
        #if DEBUG
        FileHandle.standardError.write(Data("visible \(surface) \(on)\n".utf8))
        #endif
        let fast = !visible.isEmpty
        if on { refreshReport() }
        guard let source else { return }
        Task {
            await source.setInterval(fast ? .seconds(2) : .seconds(10))
            if on { await source.readNow() }
        }
    }

    /// Asks before withdrawing a waiting request. Not wired yet: the confirmation and the
    /// `coreslot cancel` come with the actions.
    func askToCancel(_ ticket: StatusDocument.Ticket) {}

    /// Asks before stopping a running command. Not wired yet: the confirmation, the process
    /// checks and the signal come with the actions.
    func askToStop(_ hold: StatusDocument.Hold) {}

    private func run() async {
        while binary == nil && !Task.isCancelled {
            if let b = await feed.locate() {
                binary = b
            } else {
                await ingest(.problem(.notFound))
                try? await Task.sleep(for: .seconds(10))
            }
        }
        guard let binary else { return }
        let source = StatusSource(binary: binary, environment: nil, runner: feed.runner)
        self.source = source
        await source.setInterval(visible.isEmpty ? .seconds(10) : .seconds(2))
        refreshReport()
        for await r in await source.readings() { await ingest(r) }
    }

    /// One reading, the record and the report, outside the poller: a fixture shown once.
    func readOnce() async {
        guard let b = await feed.locate() else { return await ingest(.problem(.notFound)) }
        binary = b
        let r = await feed.runner.run(b.url, ["status", "--json"], environment: nil, timeout: .seconds(5))
        await ingest(interpret(r, binary: b))
        refreshReport()
        await reportTask?.value
    }

    func ingest(_ r: StatusReading) async {
        let at = feed.clock()
        (reading, readAt) = (r, at)
        let doc = document
        if let doc {
            for label in doc.holds.map(\.label) + doc.tickets.map(\.label) where labelColors[label] == nil {
                labelColors[label] = labelColors.count
            }
        }
        holdLiveSince = doc?.holds.isEmpty == false ? holdLiveSince ?? at : nil
        let dir = feed.stateDir ?? doc.flatMap { $0.stateDir.isEmpty ? nil : URL(filePath: $0.stateDir, directoryHint: .isDirectory) }
        let snapshot = await reader.update(stateDir: dir, doc: doc, at: at)
        if snapshot.newSamples > 0 { lastSample = at }
        record = snapshot
        for label in snapshot.runs.attempts.values.map(\.label) where labelColors[label] == nil {
            labelColors[label] = labelColors.count
        }
        recordState = feed.record ?? RecordState(now: at, lastSample: lastSample, holdLiveSince: holdLiveSince)
        #if DEBUG
        let summary = doc.map { "holds \($0.holds.count) tickets \($0.tickets.count) attempts \(snapshot.runs.attempts.count)" } ?? "no document"
        FileHandle.standardError.write(Data("reading \(icon) \(summary) record \(recordState)\n".utf8))
        #endif
        if !visible.isEmpty { refreshReport() }
    }

    /// `coreslot report --days 1 --json`, at most once a minute: coreslot does the counting.
    private func refreshReport() {
        guard let binary, reportTask == nil, reportAt.map({ feed.clock().timeIntervalSince($0) >= 60 }) ?? true
        else { return }
        let (runner, url) = (feed.runner, binary.url)
        reportTask = Task {
            let r = await runner.run(url, ["report", "--days", "1", "--json"], environment: nil, timeout: .seconds(10))
            if r.exitCode == 0, !r.timedOut, let decoded = try? JSONDecoder().decode(Report.self, from: r.stdout) {
                report = decoded
            }
            reportAt = feed.clock()
            reportTask = nil
        }
    }
}

/// What the record held at one reading.
struct RecordSnapshot: Sendable {
    var stateDir: URL?
    var runs = Runs()
    var tracks = HoldTracks()
    /// Memory over time from the samples, and from the app's own polls for when the record is off.
    var series = Dictionary(uniqueKeysWithValues: Series.Range.allCases.map { ($0, Series(range: $0)) })
    var polled = Dictionary(uniqueKeysWithValues: Series.Range.allCases.map { ($0, Series(range: $0, maxSilenceS: 25)) })
    var memory: MemoryLine?
    /// The run log's last 24 hours, oldest first.
    var finished: [RunLogLine] = []
    /// How many sample lines the last update read.
    var newSamples = 0
}

/// Tails the telemetry and the run log of the state directory `status` names, off the main actor.
/// It only reads: nothing under the state directory is ever written.
actor RecordReader {
    private static let keepS: TimeInterval = 24 * 60 * 60
    private static let chunk = 1 << 20
    /// At most this many chunks of each log per update: a backlog is read over several updates.
    private static let chunksPerUpdate = 16

    private var snapshot = RecordSnapshot()
    private var samples: JSONLTail?
    private var events: JSONLTail?
    private var runLog: JSONLTail?

    func update(stateDir: URL?, doc: StatusDocument?, at: Date) -> RecordSnapshot {
        if let stateDir, stateDir != snapshot.stateDir {
            let after = at.addingTimeInterval(-Self.keepS)
            snapshot = RecordSnapshot(stateDir: stateDir)
            samples = JSONLTail(stateDir: stateDir, log: .samples, startingAfter: after)
            events = JSONLTail(stateDir: stateDir, log: .events, startingAfter: after)
            runLog = JSONLTail(stateDir: stateDir, log: .runs, startingAfter: after)
        }
        let cutNS = Int64(at.addingTimeInterval(-Self.keepS).timeIntervalSince1970 * 1e9)
        snapshot.newSamples = 0
        drain(&samples) { line in
            guard let s = SampleLine(line: line), s.timeNS >= cutNS else { return }
            snapshot.newSamples += 1
            snapshot.tracks.add(s)
            for r in Series.Range.allCases { snapshot.series[r]?.add(s) }
        }
        drain(&events) { line in
            if let e = EventLine(line: line) {
                if e.timeNS >= cutNS { snapshot.runs.apply(e) }
            } else if let m = MemoryLine(line: line), m.timeNS >= snapshot.memory?.timeNS ?? cutNS {
                snapshot.memory = m
            }
        }
        drain(&runLog) { line in
            if let r = RunLogLine(line: line), r.timeNS >= cutNS { snapshot.finished.append(r) }
        }
        snapshot.finished.removeAll { $0.timeNS < cutNS }
        snapshot.runs.prune(endedBefore: at.addingTimeInterval(-Self.keepS))
        if let doc {
            snapshot.tracks.add(doc, at: at)
            snapshot.tracks.keep(only: Set(doc.holds.map(\.name)))
            for r in Series.Range.allCases { snapshot.polled[r]?.add(doc, at: at) }
        }
        return snapshot
    }

    /// The complete lines there now, a chunk at a time, up to `chunksPerUpdate` chunks; the rest
    /// comes with the next update. A read can give no lines before the end, so the tail's own
    /// `atEnd` ends the loop. A log that cannot be read gives none until it can.
    private func drain(_ tail: inout JSONLTail?, _ each: (Data) -> Void) {
        guard var t = tail else { return }
        for _ in 0..<Self.chunksPerUpdate {
            guard let lines = try? t.read(maxBytes: Self.chunk) else { break }
            lines.forEach(each)
            if t.atEnd { break }
        }
        tail = t
    }
}
