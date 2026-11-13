import CoreslotKit
import Foundation
import Observation

/// The places that show the live view; while any is visible the view is at most 2 s behind.
enum Surface: Hashable { case popover, timeline }

/// Where readings come from: the `coreslot` found on this machine, or, in a debug build, a fixture.
struct Feed: Sendable {
    /// The `coreslot` to use: the one chosen in Settings, when given, alone; else the one found.
    let locate: @Sendable (_ chosen: URL?) async -> CoreslotBinary?
    let runner: Runner
    #if DEBUG
    /// Fixtures only: the record read here instead of at the document's `state_dir`, the
    /// fixture's clock, and the record's state as the variant names it.
    var stateDir: URL? = nil
    var clock: @Sendable () -> Date = { Date() }
    var record: RecordState? = nil
    #else
    let stateDir: URL? = nil, record: RecordState? = nil
    func clock() -> Date { Date() }
    #endif
    var inspector: any ProcessInspector = DarwinProcessInspector()
    /// Sends a signal; 0 or the errno.
    var signal: @Sendable (pid_t, Int32) -> Int32 = { kill($0, $1) == 0 ? 0 : errno }
    /// The choices made in Settings are kept in the app's defaults; a fixture keeps none.
    var keepsChoices = false

    static let live = Feed(
        locate: { chosen in
            let path = ProcessInfo.processInfo.environment["PATH"]
            let found = chosen.map { Locate.find(override: $0, directories: [], path: nil) }
                ?? Locate.find(override: nil, directories: Locate.standardDirectories, path: path)
            guard let url = found else { return nil }
            return await CoreslotBinary.probe(url, environment: nil)
        },
        runner: .process, keepsChoices: true)
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
    /// Tickets whose cancel coreslot accepted, until they leave the queue.
    private(set) var cancelRequested: Set<String> = []
    /// Holds whose process the app could not read: no stop button, and the quiet line says so.
    private(set) var unchecked: Set<String> = []
    /// Chosen in Settings: another `coreslot` than the one found.
    private(set) var chosenBinary: URL?
    /// Chosen in Settings, for development: a state directory of its own, passed to every
    /// `coreslot` the app runs as `CORESLOT_STATE_DIR`.
    private(set) var chosenStateDir: URL?

    @ObservationIgnored let feed: Feed
    @ObservationIgnored private let reader = RecordReader()
    @ObservationIgnored private var source: StatusSource?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var visible: Set<Surface> = []
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var holdLiveSince: Date?
    @ObservationIgnored private var reportAt: Date?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    /// One confirmation at a time.
    @ObservationIgnored private var acting = false
    /// Counts the restarts a new choice in Settings makes; what an older loop brings is dropped.
    @ObservationIgnored private var generation = 0
    /// The wait before looking for `coreslot` again; showing a surface cuts it short.
    @ObservationIgnored private var nap: Task<Void, Never>?

    private static let binaryKey = "coreslot", stateDirKey = "stateDirectory"

    init(feed: Feed) {
        self.feed = feed
        chosenBinary = defaults?.url(forKey: Self.binaryKey)
        chosenStateDir = defaults?.url(forKey: Self.stateDirKey)
    }

    private var defaults: UserDefaults? { feed.keepsChoices ? .standard : nil }

    /// The feed's runner, with the chosen state directory laid over each run's environment.
    private var runner: Runner {
        guard let dir = chosenStateDir else { return feed.runner }
        let (base, extra) = (feed.runner, ["CORESLOT_STATE_DIR": dir.path])
        return Runner { await base.run($0, $1, environment: ($2 ?? [:]).merging(extra) { $1 }, timeout: $3) }
    }

    /// Another `coreslot`, or nil for the one found; the app starts over with it.
    func choose(binary url: URL?) {
        chosenBinary = url
        defaults?.set(url, forKey: Self.binaryKey)
        restart()
    }

    /// Another state directory, or nil for coreslot's own; the app starts over with it.
    func choose(stateDir url: URL?) {
        chosenStateDir = url
        defaults?.set(url, forKey: Self.stateDirKey)
        restart()
    }

    private func restart() {
        generation += 1
        loop?.cancel()
        (loop, source, binary, report, reportAt, reportTask) = (nil, nil, nil, nil, nil, nil)
        (lastSample, holdLiveSince) = (nil, nil)
        start()
    }

    var now: Date { feed.clock() }

    var icon: IconState { reading.map(IconState.init) ?? .idle }

    /// The document; a reading of notices alone has none, and feeds nothing.
    var document: StatusDocument? {
        guard case .document(let doc, _) = reading else { return nil }
        return doc
    }

    func start() {
        guard loop == nil else { return }
        let generation = generation
        loop = Task { await run(generation) }
    }

    func setVisible(_ surface: Surface, _ on: Bool) {
        if on { visible.insert(surface) } else { visible.remove(surface) }
        #if DEBUG
        Present.log("visible \(surface) \(on)")
        #endif
        let fast = !visible.isEmpty
        if on { refreshReport() }
        guard let source else { if on { nap?.cancel() }; return }
        Task {
            await source.setInterval(fast ? .seconds(2) : .seconds(10))
            if on { await source.readNow() }
        }
    }

    /// Asks before withdrawing a waiting request, then runs `coreslot cancel`.
    func askToCancel(_ ticket: StatusDocument.Ticket) {
        guard let binary, !acting else { return }
        acting = true
        Task {
            defer { acting = false }
            guard Confirm.ask(AlertText.cancel(ticket)) else { return }
            switch await cancel(ticketID: ticket.id, using: binary, runner: runner) {
            case .requested: cancelRequested.insert(ticket.id)
            case .refused(let now):
                await ingest(now)
                Confirm.tell(AlertText.cancelRefused(ticketID: ticket.id, now: now))
            case .failed(let problem): Confirm.tell(AlertText.cancelFailed(problem))
            }
        }
    }

    /// Checks the hold's process, asks, checks again, and only then sends `SIGTERM`.
    func askToStop(_ hold: StatusDocument.Hold) {
        guard let binary, !acting else { return }
        acting = true
        let (runner, inspector) = (runner, feed.inspector)
        Task {
            defer { acting = false }
            let shown = await prepareStop(holdName: hold.name, using: binary, runner: runner, inspector: inspector)
            guard case .ready(let pid, let facts) = shown else { return tell(stop: shown) }
            guard Confirm.ask(AlertText.stop(hold, pid: pid, facts: facts)) else { return }
            let again = recheck(await prepareStop(holdName: hold.name, using: binary, runner: runner, inspector: inspector), shown: shown)
            guard case .ready = again else { return tell(stop: again) }
            let outcome = sendStop(again, inspector: inspector, signal: feed.signal)
            #if DEBUG
            Present.log("stop \(outcome)")
            #endif
            if let words = AlertText.stopOutcome(outcome) { Confirm.tell(words) }
            await source?.readNow()
        }
    }

    private func tell(stop c: StopCheck) {
        #if DEBUG
        Present.log("stop \(c)")
        #endif
        if let words = AlertText.refusal(c) { Confirm.tell(words) }
    }

    private func run(_ generation: Int) async {
        while binary == nil && !Task.isCancelled {
            if let b = await feed.locate(chosenBinary) {
                guard generation == self.generation else { return }
                binary = b
            } else {
                guard generation == self.generation else { return }
                await ingest(.problem(.notFound))
                let nap = Task { [visible] in _ = try? await Task.sleep(for: visible.isEmpty ? .seconds(10) : .seconds(2)) }
                self.nap = nap
                await nap.value
            }
        }
        guard let binary, generation == self.generation else { return }
        let source = StatusSource(binary: binary, environment: nil, runner: runner)
        self.source = source
        await source.setInterval(visible.isEmpty ? .seconds(10) : .seconds(2))
        refreshReport()
        for await r in await source.readings() where generation == self.generation {
            await ingest(r)
            // The file is gone from where it was found: look for it again, wherever it is now.
            if r == .problem(.notFound) { return restart() }
        }
    }

    #if DEBUG
    /// One reading, the record and the report, outside the poller: a fixture shown once.
    func readOnce() async {
        guard let b = await feed.locate(chosenBinary) else { return await ingest(.problem(.notFound)) }
        binary = b
        let r = await runner.run(b.url, ["status", "--json"], environment: nil, timeout: .seconds(5))
        await ingest(interpret(r, binary: b))
        refreshReport()
        await reportTask?.value
    }
    #endif

    func ingest(_ r: StatusReading) async {
        let at = feed.clock()
        (reading, readAt) = (r, at)
        let doc = document
        holdLiveSince = doc?.holds.isEmpty == false ? holdLiveSince ?? at : nil
        cancelRequested.formIntersection(doc?.tickets.filter { $0.state != "dead" }.map(\.id) ?? [])
        unchecked = Set((doc?.holds ?? []).filter { !canInspect($0, inspector: feed.inspector) }.map(\.name))
        let dir = feed.stateDir ?? doc.flatMap { $0.stateDir.isEmpty ? nil : URL(filePath: $0.stateDir, directoryHint: .isDirectory) }
        let snapshot = await reader.update(stateDir: dir, doc: doc, at: at)
        if snapshot.newSamples > 0 { lastSample = at }
        record = snapshot
        let labels = (doc?.holds.map(\.label) ?? []) + (doc?.tickets.map(\.label) ?? []) + snapshot.runs.attempts.values.map(\.label)
        for label in labels where labelColors[label] == nil { labelColors[label] = labelColors.count }
        recordState = feed.record ?? RecordState(now: at, lastSample: lastSample, holdLiveSince: holdLiveSince)
        #if DEBUG
        let summary = doc.map { "holds \($0.holds.count) tickets \($0.tickets.count) attempts \(snapshot.runs.attempts.count)" } ?? "no document"
        Present.log("reading \(icon) \(summary) record \(recordState)")
        #endif
        if !visible.isEmpty { refreshReport() }
        #if DEBUG
        if let label = Present.askStop, let h = doc?.holds.first(where: { $0.label == label && $0.stoppable == true }) {
            Present.askStop = nil
            askToStop(h)
        }
        #endif
    }

    /// `coreslot report --days 1 --json`, at most once a minute: coreslot does the counting.
    private func refreshReport() {
        guard let binary, reportTask == nil, reportAt.map({ feed.clock().timeIntervalSince($0) >= 60 }) ?? true
        else { return }
        let (runner, url, generation) = (runner, binary.url, generation)
        reportTask = Task {
            let r = await runner.run(url, ["report", "--days", "1", "--json"], environment: nil, timeout: .seconds(10))
            guard generation == self.generation else { return }
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
    /// Memory over time from the samples, one series per range.
    var series = Dictionary(uniqueKeysWithValues: Series.Range.allCases.map { ($0, Series(range: $0)) })
    var memory: MemoryLine?
    /// The run log's last 24 hours, oldest first.
    var finished: [RunLogLine] = []
    /// How many sample lines the last update read.
    var newSamples = 0
}

/// Tails the telemetry and the run log of the state directory `status` names, off the main actor.
/// It only reads: nothing under the state directory is ever written.
actor RecordReader {
    static let keepS: Int64 = 24 * 60 * 60
    private static let chunk = 1 << 20
    /// At most this many chunks of each log per update: a backlog is read over several updates.
    private static let chunksPerUpdate = 16

    private var snapshot = RecordSnapshot()
    private var samples: JSONLTail?
    private var events: JSONLTail?
    private var runLog: JSONLTail?

    func update(stateDir: URL?, doc: StatusDocument?, at: Date) -> RecordSnapshot {
        if let stateDir, stateDir != snapshot.stateDir {
            snapshot = RecordSnapshot(stateDir: stateDir)
            samples = JSONLTail(stateDir: stateDir, log: .samples)
            events = JSONLTail(stateDir: stateDir, log: .events)
            runLog = JSONLTail(stateDir: stateDir, log: .runs)
        }
        let (cut, atNS) = (at.addingTimeInterval(-Double(Self.keepS)), at.nanosecondsSince1970)
        let cutNS = cut.nanosecondsSince1970
        snapshot.newSamples = 0
        drain(&samples) { line in
            guard let s = SampleLine(line: line), s.timeNS >= cutNS else { return }
            snapshot.newSamples += 1
            snapshot.tracks.add(s, now: at)
            for r in Series.Range.allCases { snapshot.series[r]?.add(s, now: at) }
        }
        drain(&events) { line in
            if let e = EventLine(line: line) {
                if e.timeNS >= cutNS { snapshot.runs.apply(e) }
            } else if let m = MemoryLine(line: line), placed(m.timeNS, nowNS: atNS, spanS: Self.keepS),
                      // The newest usable line by its time, as the series places samples.
                      !(snapshot.memory.map { placed($0.timeNS, nowNS: atNS, spanS: Self.keepS) && $0.timeNS > m.timeNS } ?? false) {
                snapshot.memory = m
            }
        }
        drain(&runLog) { line in
            if let r = RunLogLine(line: line), r.timeNS >= cutNS { snapshot.finished.append(r) }
        }
        snapshot.finished.removeAll { $0.timeNS < cutNS }
        snapshot.runs.prune(endedBefore: cut)
        if let doc {
            snapshot.tracks.add(doc, at: at)
            snapshot.tracks.keep(only: Set(doc.holds.map(\.name)))
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
