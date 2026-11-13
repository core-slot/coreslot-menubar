import CoreslotKit
import Foundation
import Observation

/// The places that show the live view; while any is visible the view is at most 2 s behind.
enum Surface: Hashable { case popover, timeline }

/// Where readings come from: the `coreslot` found on this machine, or, in a debug build, a fixture.
struct Feed: Sendable {
    /// Where the `coreslot` to use is now: the one chosen in Settings, when given, alone; else the one found.
    let find: @Sendable (_ chosen: URL?) -> URL?
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
        find: { chosen in
            chosen.map { Locate.find(override: $0, directories: [], path: nil) }
                ?? Locate.find(override: nil, directories: Locate.standardDirectories, path: ProcessInfo.processInfo.environment["PATH"])
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
    private(set) var labelColors = LabelColors()
    /// Holds whose process the app could not read: no stop button, and the quiet line says so.
    /// Only the popover shows it, so it is read only while the popover is visible.
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
    @ObservationIgnored private var transitions = LogTransitions()

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
        Log.settings.say("coreslot chosen: \(url?.path ?? "the one found")")
        restart()
    }

    /// Another state directory, or nil for coreslot's own; the app starts over with it.
    func choose(stateDir url: URL?) {
        chosenStateDir = url
        defaults?.set(url, forKey: Self.stateDirKey)
        Log.settings.say("state directory chosen: \(url?.path ?? "coreslot's own")")
        restart()
    }

    private func restart() {
        generation += 1
        loop?.cancel()
        (loop, source, binary, report, reportAt, reportTask) = (nil, nil, nil, nil, nil, nil)
        (lastSample, holdLiveSince) = (nil, nil)
        transitions.restarted()
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
        let interval = StatusSource.interval(visible: !visible.isEmpty)
        if on { refreshReport() }
        if on, surface == .popover { checkHolds() }
        guard let source else { return }
        Task {
            await source.setInterval(interval)
            if on { await source.readNow() }
        }
    }

    /// Asks before withdrawing a waiting request, then runs `coreslot cancel`.
    func askToCancel(_ ticket: StatusDocument.Ticket) {
        let id = SafeText.display(ticket.id)
        guard let binary, !acting else { return Log.actions.say("cancel not asked, \(acting ? "another action is in flight" : "no coreslot"): ticket \(id)") }
        acting = true
        Log.actions.say("cancel asked: ticket \(id)")
        Task {
            defer { acting = false }
            guard Confirm.ask(AlertText.cancel(ticket)) else { return Log.actions.say("cancel declined: ticket \(id)") }
            switch await cancel(ticketID: ticket.id, using: binary, runner: runner) {
            case .requested:
                Log.actions.say("cancel requested: ticket \(id)")
                await source?.readNow() // `status` lists the request, as it does one made elsewhere
            case .refused(let now):
                Log.actions.say("cancel refused, exit 75; status now \(LogTransitions.Kind(now).text): ticket \(id)")
                await ingest(now)
                Confirm.tell(AlertText.cancelRefused(ticketID: ticket.id, now: now))
            case .failed(let problem):
                Log.actions.say("cancel failed: \(AlertText.cancelFailed(problem)) Ticket \(id)", failure: true)
                Confirm.tell(AlertText.cancelFailed(problem))
            }
        }
    }

    /// Checks the hold's process, asks, checks again, and only then sends `SIGTERM`.
    func askToStop(_ hold: StatusDocument.Hold) {
        let (runner, inspector, name) = (runner, feed.inspector, SafeText.display(hold.name))
        let who = "pid \(hold.pid), started unknown, hold \(name)"
        guard let binary, !acting else { return Log.actions.say("stop not asked, \(acting ? "another action is in flight" : "no coreslot"): \(who)") }
        acting = true
        Log.actions.say("stop asked: \(who)")
        Task {
            defer { acting = false }
            let end = await stop(holdName: hold.name, using: binary, runner: runner, inspector: inspector,
                                 ask: { @MainActor in Confirm.ask(AlertText.stop(hold, pid: $0, facts: $1)) }, signal: feed.signal)
            // The pid and the start time of one read: the check that ended it, or the last before the signal.
            let who = { (r: (pid: pid_t?, started: Int64?)) in "pid \(r.pid.map(String.init) ?? String(hold.pid)), started \(r.started.map(String.init) ?? "unknown"), hold \(name)" }
            switch end {
            case .notAsked(let c), .notSent(let c):
                guard let words = AlertText.refusal(c) else { return }
                Log.actions.say("stop not sent, \(words.log): \(who(c.read))", failure: c != .gone && c != .changed)
                Confirm.tell(words.alert)
            case .declined(let c): Log.actions.say("stop declined: \(who(c.read))")
            case .signalled(let outcome, let c):
                let words = AlertText.stopOutcome(outcome)
                let started = if case .changed(let s) = outcome { s } else { c.read.started }
                Log.actions.say("stop \(words.log): SIGTERM to \(who((c.read.pid, started)))", failure: outcome != .sent)
                if let alert = words.alert { Confirm.tell(alert) }
                await source?.readNow()
            }
        }
    }

    /// The one polling loop; a new choice in Settings cancels it from outside and starts another.
    private func run(_ generation: Int) async {
        let source = newSource()
        self.source = source
        await source.setInterval(StatusSource.interval(visible: !visible.isEmpty))
        for await polled in source.readings() where generation == self.generation { await take(polled) }
    }

    private func newSource() -> StatusSource {
        let (find, chosen) = (feed.find, chosenBinary)
        return StatusSource(find: { find(chosen) }, runner: runner)
    }

    /// The `coreslot` a reading came from, then the reading.
    private func take(_ p: Polled) async {
        transitions.located(p.binary).map(Log.status.say)
        let appeared = binary == nil && p.binary != nil
        binary = p.binary
        if appeared { refreshReport() }
        await ingest(p.reading)
    }

    #if DEBUG
    /// One reading, the record and the report, outside the poller: a fixture shown once.
    func readOnce() async {
        await take(await newSource().read())
        await reportTask?.value
    }
    #endif

    func ingest(_ r: StatusReading) async {
        let at = feed.clock()
        (reading, readAt) = (r, at)
        transitions.reading(r).forEach(Log.status.say)
        let doc = document
        holdLiveSince = doc?.holds.isEmpty == false ? holdLiveSince ?? at : nil
        if visible.contains(.popover) { checkHolds() }
        let dir = feed.stateDir ?? doc.flatMap { $0.stateDir.isEmpty ? nil : URL(filePath: $0.stateDir, directoryHint: .isDirectory) }
        let snapshot = await reader.update(stateDir: dir, doc: doc, at: at)
        if snapshot.newSamples > 0 { lastSample = at }
        record = snapshot
        transitions.read(errors: snapshot.errors).forEach(Log.telemetry.say)
        let labels = (doc?.holds.map(\.label) ?? []) + (doc?.tickets.map(\.label) ?? []) + snapshot.runs.attempts.values.map(\.label)
        labelColors.see(labels, at: at)
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

    private func checkHolds() { unchecked = Set((document?.holds ?? []).filter { !canInspect($0, inspector: feed.inspector) }.map(\.name)) }

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
    /// Why a log could not be read in the last update.
    var errors: [String] = []
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
        (snapshot.newSamples, snapshot.errors) = (0, [])
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
        snapshot.runs.prune(endedBefore: cut, live: doc)
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
            let lines: [Data], stream = t.current.deletingPathExtension().lastPathComponent // an error may be either generation's
            do { lines = try t.read(maxBytes: Self.chunk) } catch { snapshot.errors.append("\(stream): errno \((error as? POSIXError)?.code.rawValue ?? -1)"); break }
            lines.forEach(each)
            if t.atEnd { break }
        }
        tail = t
    }
}
