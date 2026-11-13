#if DEBUG
import AppKit
import CoreslotKit
import SwiftUI

/// Debug-only launch flags. `--fixture NAME` runs the whole app over a recorded state;
/// `--present NAME[,NAME…]|all [--appearance light|dark]` opens the popover's content over each in
/// an ordinary window, or for `timeline[-RANGE][:NAME][@SECONDS]` the timeline window over that
/// variant (the queue by default) at that range (15m, 1h, 6h, 24h; 15m by default), scrolled back
/// by SECONDS if given, and prints
/// `present-window <kind> <name> <window number>` per window, then `present-ready`. `--fixtures-dir DIR` names the fixtures; by default they are found from the
/// executable up to `Package.swift`. `--answer yes|no` answers every confirmation unseen and
/// prints its text to stderr; with `--ask-stop LABEL` the first stoppable hold of that label is
/// asked to stop once: together they drive a stop through the app's own path. `settings` shows
/// Settings over the queue with launch at login as this copy finds it, and `settings-on`,
/// `settings-approval` and `settings-off` with the service's status shown as that. `--measure`
/// runs the live app through phases and prints what each cost (see `measureIfAsked`).
@MainActor
enum Present {
    struct Variant: Sendable {
        let name: String
        var fixture = "queue"
        var version = Version(0, 8, 0)
        var record: RecordState?
        var change: (@Sendable (inout [String: Any]) -> Void)?
        var result: (@Sendable (Data) -> RunResult)?
        /// False: the app cannot read any hold's process.
        var readable = true
        /// Two hours of made-up record before the queue's moment, for the timeline's look.
        var night = false

        /// The 0.7.0 document is the queue fixture with keys removed; its record is the queue's.
        var telemetry: String { fixture == "0.7.0" ? "queue" : fixture }
    }

    static let variants: [Variant] = [
        .init(name: "idle", fixture: "idle"),
        .init(name: "queue"),
        .init(name: "cancelled", fixture: "cancelled"),
        .init(name: "dead", fixture: "dead"),
        .init(name: "stopped", fixture: "stopped"),
        .init(name: "no-typical", fixture: "no-typical"),
        .init(name: "0.7.0", fixture: "0.7.0", version: Version(0, 7, 0)),
        .init(name: "normal", change: { edit(&$0, "watch") { $0["learning"] = 0 } }),
        .init(name: "yellow", change: level("yellow")),
        .init(name: "red", change: level("red")),
        .init(name: "floor", change: level("floor")),
        .init(name: "degraded", change: {
            $0["degraded"] = ["reason": "the queue could not be read", "first_ns": 1_794_508_090_000_000_000, "count": 3, "malformed": false]
        }, result: exit3),
        .init(name: "format", change: { $0["format"] = 3; $0["format_understood"] = false }, result: exit3),
        .init(name: "config-error", change: {
            $0["config_error"] = "config.toml: line 4: unknown key \"reserv\""
            $0["mem"] = NSNull()
            edit(&$0, "tickets") { $0["expected_wait_s"] = NSNull() }
        }, result: exit3),
        .init(name: "schema-2", result: { _ in RunResult(exitCode: 0, stdout: Data(#"{"schema": 2}"#.utf8)) }),
        .init(name: "not-found"),
        .init(name: "state-unreadable", result: { _ in RunResult(exitCode: 3) }),
        .init(name: "exit-64", result: { _ in RunResult(exitCode: 64) }),
        .init(name: "exit-70", result: { _ in RunResult(exitCode: 70) }),
        .init(name: "malformed", result: { _ in RunResult(exitCode: 0, stdout: Data(#"{"schema": 1, "holds": ["#.utf8)) }),
        .init(name: "timeout", result: { _ in RunResult(exitCode: 143, timedOut: true) }),
        .init(name: "record-off", record: .looksOff),
        .init(name: "shortfall", change: {
            edit(&$0, "mem") { $0["reserved_mib"] = 5864; $0["room_mib"] = -2950; $0["free_mib"] = 0 }
            edit(&$0, "holds") { h in
                let long = h["label"] as? String == "demo:long"
                h["footprint_mib"] = long ? 900 : 300
                if long { h["need_mib"] = 5800 }
            }
        }),
        .init(name: "untrusted", change: {
            $0["degraded"] = ["reason": "lock\u{202E}txt.exe\nnext", "first_ns": 1_794_508_090_000_000_000, "count": 1, "malformed": false]
            var holds = $0["holds"] as! [[String: Any]]
            holds[0]["label"] = "build\u{0007}\\x \u{202E}gpj.exe"
            holds[1]["container"] = true
            $0["holds"] = holds
            var tickets = $0["tickets"] as! [[String: Any]]
            tickets[1]["label"] = "zero\u{200B}width\u{E0041}tag"
            $0["tickets"] = tickets
        }, result: exit3),
        .init(name: "many", change: many),
        .init(name: "unchecked", readable: false),
        .init(name: "night", night: true),
        .init(name: "record-off-night", record: .looksOff, night: true),
    ]

    /// The confirmations and a refusal, over the queue fixture. An alert draws only while it runs
    /// modally, so one may be named per launch, and it is shown after every other window.
    static let alerts = ["alert-stop", "alert-cancel", "alert-refused"]

    /// Settings over the queue; nil is launch at login as this copy finds it.
    static let settings: [String: LoginItem.State?] = [
        "settings": nil, "settings-on": .enabled, "settings-approval": .requiresApproval, "settings-off": .notRegistered,
    ]

    static let answer: Bool? = switch value("--answer", CommandLine.arguments) {
    case nil: nil
    case "yes": true
    case "no": false
    case let other?: fail("--answer takes yes or no, not \(other)")
    }

    static var askStop = value("--ask-stop", CommandLine.arguments)

    static func log(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    static func runIfAsked(_ args: [String]) -> Bool {
        guard let list = value("--present", args) else { return false }
        let fixtures = fixturesDirectory(args)
        let chosen = list == "all" ? variants.map(\.name) + ["icons"] + timelines + settings.keys.sorted() : list.split(separator: ",").map(String.init)
        if chosen.filter(alerts.contains).count > 1 { fail("name one of \(alerts.joined(separator: ", ")) per launch") }
        for name in chosen where name != "icons" && !alerts.contains(name) && timeline(name) == nil && settings[name] == nil
            && !variants.contains(where: { $0.name == name }) {
            fail("no variant \(name); the variants are \(variants.map(\.name).joined(separator: ", ")), icons, \(alerts.joined(separator: ", ")), \(settings.keys.sorted().joined(separator: ", ")), timeline[-15m|-1h|-6h|-24h][:VARIANT] and all")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        switch value("--appearance", args) {
        case nil: break
        case "light": app.appearance = NSAppearance(named: .aqua)
        case "dark": app.appearance = NSAppearance(named: .darkAqua)
        case let other?: fail("--appearance takes light or dark, not \(other)")
        }
        Task {
            for (i, name) in chosen.enumerated() {
                if name == "icons" {
                    show(IconBoard(), kind: "icons", name: name, at: i)
                    continue
                }
                if alerts.contains(name) { continue }
                if let state = settings[name] {
                    let store = Store(feed: feed(variants.first { $0.name == "queue" }!, fixtures: fixtures, live: false))
                    await store.readOnce()
                    show(SettingsView(store: store, loginItem: state.map { LoginItem(showing: $0) } ?? LoginItem()), kind: "settings", name: name, at: i)
                    continue
                }
                if let (range, variant, back) = timeline(name) {
                    let store = Store(feed: feed(variant, fixtures: fixtures, live: false))
                    await store.readOnce()
                    let end = back.map { store.now.addingTimeInterval(-$0) }
                    show(TimelineView(store: store, range: range, end: end).frame(width: 980, height: 760), kind: "timeline", name: name, at: i)
                    continue
                }
                let store = Store(feed: feed(variants.first { $0.name == name }!, fixtures: fixtures, live: false))
                await store.readOnce()
                show(PopoverView(store: store, openTimeline: {}).environment(\.revealsRowActions, true), kind: "popover", name: name, at: i)
            }
            try? await Task.sleep(for: .milliseconds(500))
            if let name = chosen.first(where: alerts.contains) { return runAlert(name, fixtures: fixtures) }
            print("present-ready")
            fflush(stdout)
        }
        app.activate()
        app.run()
        return true
    }

    /// The feed of `--fixture NAME`, the whole app over one variant; nil without the flag.
    static func fixtureFeed(_ args: [String]) -> Feed? {
        guard let name = value("--fixture", args) else { return nil }
        guard let v = variants.first(where: { $0.name == name }) else {
            fail("no variant \(name); the variants are \(variants.map(\.name).joined(separator: ", "))")
        }
        return feed(v, fixtures: fixturesDirectory(args), live: true)
    }

    /// `--measure PHASE:SECONDS[,PHASE:SECONDS…]`, each PHASE `closed`, `popover` or `timeline`:
    /// the live app runs the phases in turn, then quits. For `popover` the popover's content, and
    /// for `timeline` the timeline window at 24 h, is open in an ordinary window above the others,
    /// in place of a person who opened it; `closed` opens nothing. Prints `measure pid <pid>`,
    /// `measure <phase> begins`, and at each phase's end its wall time and the CPU time of the app
    /// and of the `coreslot` runs it reaped, from `getrusage`, each as a share of one core.
    static func measureIfAsked(store: Store) {
        guard let list = value("--measure", CommandLine.arguments) else { return }
        let phases = list.split(separator: ",").map { item -> (String, Int) in
            let p = item.split(separator: ":")
            guard p.count == 2, ["closed", "popover", "timeline"].contains(String(p[0])), let s = Int(p[1]), s > 0 else {
                fail("--measure takes PHASE:SECONDS[,PHASE:SECONDS…], each PHASE closed, popover or timeline")
            }
            return (String(p[0]), s)
        }
        log("measure pid \(getpid())")
        Task {
            for (phase, seconds) in phases {
                let window: NSWindow? = switch phase {
                case "popover":
                    measured(PopoverView(store: store, openTimeline: {}).background(WindowVisibility { store.setVisible(.popover, $0) }))
                case "timeline":
                    measured(TimelineView(store: store, range: .day).frame(width: 980, height: 760)
                        .background(WindowVisibility { store.setVisible(.timeline, $0) }))
                default: nil
                }
                let (me, children, from) = (cpu(RUSAGE_SELF), cpu(RUSAGE_CHILDREN), ContinuousClock.now)
                log("measure \(phase) begins")
                try? await Task.sleep(for: .seconds(seconds))
                let d = (ContinuousClock.now - from).components
                let wall = Double(d.seconds) + Double(d.attoseconds) / 1e18
                let (a, c) = (cpu(RUSAGE_SELF) - me, cpu(RUSAGE_CHILDREN) - children)
                log(String(format: "measure %@ %.1f s: app %.2f s cpu, %.3f %% of a core; children %.2f s cpu, %.3f %% of a core",
                           phase, wall, a, 100 * a / wall, c, 100 * c / wall))
                window?.close()
            }
            NSApp.terminate(nil)
        }
    }

    private static func measured(_ view: some View) -> NSWindow {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        // Above the others, as the menu bar's panel is, so it stays on screen.
        window.level = .floating
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX + 40, y: screen.maxY - 40))
        window.orderFrontRegardless()
        return window
    }

    /// User and system CPU seconds of `who`.
    private static func cpu(_ who: Int32) -> Double {
        var u = rusage()
        getrusage(who, &u)
        let s = { (t: timeval) in Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// What `all` shows of the timeline: each range over the queue, and the record looking off.
    static let timelines = [
        "timeline-15m", "timeline-1h", "timeline-6h", "timeline-24h", "timeline:record-off",
        "timeline-15m:night", "timeline-1h:night", "timeline-6h:night", "timeline-24h:night", "timeline-1h:record-off-night",
    ]

    /// `timeline[-RANGE][:VARIANT][@SECONDS]`; nil for any other name.
    private static func timeline(_ name: String) -> (Series.Range, Variant, TimeInterval?)? {
        guard name.hasPrefix("timeline") else { return nil }
        let at = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = at[0].dropFirst("timeline".count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let ranges: [String: Series.Range] = ["": .quarterHour, "-15m": .quarterHour, "-1h": .hour, "-6h": .sixHours, "-24h": .day]
        guard let range = ranges[String(parts.first ?? "")] else { return nil }
        let back = at.count > 1 ? TimeInterval(at[1]) : nil
        if at.count > 1 && back == nil { return nil }
        let variant = parts.count > 1 ? String(parts[1]) : "queue"
        return variants.first { $0.name == variant }.map { (range, $0, back) }
    }

    private static var windows: [NSWindow] = []

    private static func show(_ view: some View, kind: String, name: String, at index: Int) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: host)
        window.styleMask = kind == "timeline" ? [.titled, .closable, .resizable] : [.titled, .closable]
        window.title = "\(kind) · \(name)"
        window.isReleasedWhenClosed = false
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let columns = max(1, Int(screen.width / 430))
        window.setFrameTopLeftPoint(NSPoint(
            x: screen.minX + CGFloat(index % columns) * 430, y: screen.maxY - CGFloat(index / columns % 8) * 40))
        window.orderFrontRegardless()
        windows.append(window)
        print("present-window \(kind) \(name) \(window.windowNumber)")
        fflush(stdout)
    }

    /// Runs the alert modally until it is answered; its number and `present-ready` are printed
    /// once it is on screen.
    private static func runAlert(_ name: String, fixtures: URL) {
        guard let doc = try? StatusDocument.decode(Data(contentsOf: fixtures.appending(path: "status-queue.json"))),
              let hold = doc.holds.first(where: { $0.stoppable == true }), let ticket = doc.tickets.first
        else { fail("cannot read status-queue.json in \(fixtures.path)") }
        let args = ["coreslot", "run", "--restart=yes", "--label", "build\u{202E}gpj.exe", "--", "make", "test\u{2028}all"]
        let alert = switch name {
        case "alert-stop":
            Confirm.make(AlertText.stop(hold, pid: pid_t(hold.pid), facts: ProcessFacts(
                executable: FixtureInspector.root, startSeconds: 0, arguments: args)))
        case "alert-cancel": Confirm.make(AlertText.cancel(ticket))
        default: Confirm.make(AlertText.refusal(.refused(""))!)
        }
        // The modal loop runs inside this task, so the main queue waits; a timer of its mode does not.
        // The window on screen is not `alert.window` but one the system draws for it: this
        // process's only window on screen.
        RunLoop.main.add(Timer(timeInterval: 0.5, repeats: false) { _ in
            let shown = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let number = shown.first { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }?[kCGWindowNumber as String] as? Int ?? 0
            print("present-window alert \(name) \(number)")
            print("present-ready")
            fflush(stdout)
        }, forMode: .modalPanel)
        alert.runModal()
    }

    /// A variant's readings: `status` and `report` answer from the fixture, nothing else runs.
    private static func feed(_ v: Variant, fixtures: URL, live: Bool) -> Feed {
        let original: Data
        do { original = try Data(contentsOf: fixtures.appending(path: "status-\(v.fixture).json")) } catch {
            fail("cannot read the fixture status-\(v.fixture).json in \(fixtures.path): \(error)")
        }
        var stdout = original
        if let change = v.change, var raw = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] {
            change(&raw)
            stdout = (try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])) ?? original
        }
        let status = v.result?(stdout) ?? RunResult(exitCode: 0, stdout: stdout)
        let report = RunResult(exitCode: 0, stdout: (try? Data(contentsOf: fixtures.appending(path: "report.json"))) ?? Data())
        var telemetry = fixtures.appending(path: "telemetry-\(v.telemetry)", directoryHint: .isDirectory)
        let then = newest(status: original, telemetry: telemetry)
        if v.night { telemetry = night(before: then) }
        let launched = Date()
        let binary = CoreslotBinary(url: URL(filePath: "/fixture/coreslot"), version: v.version)
        let found = v.name != "not-found"
        let runner = Runner { _, args, _, _ -> RunResult in
            switch args.first {
            case "status": return status
            case "report": return report
            default: return RunResult(exitCode: 64)
            }
        }
        // A fixture's moment is its newest time; `--present` stays there, `--fixture` moves on.
        let clock: @Sendable () -> Date
        if live {
            clock = { then.addingTimeInterval(Date().timeIntervalSince(launched)) }
        } else {
            clock = { then }
        }
        let locate: @Sendable (URL?) async -> CoreslotBinary? = { _ in found ? binary : nil }
        return Feed(
            locate: locate, runner: runner, stateDir: telemetry, clock: clock, record: v.record,
            inspector: FixtureInspector(readable: v.readable), signal: { _, _ in EPERM })
    }

    /// Two hours of made-up record before `then`, written under the temporary directory, never a
    /// state directory: runs of three labels with waits and their reasons, a watchdog stop and its
    /// restart, a run that went on after its timeout, a six-minute silence and a failed reading.
    private nonisolated static func night(before then: Date) -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "coreslot-present-night-\(getpid())", directoryHint: .isDirectory)
        for sub in ["telemetry", "log"] {
            try? FileManager.default.createDirectory(at: dir.appending(path: sub), withIntermediateDirectories: true)
        }
        let end = Int64(then.timeIntervalSince1970), start = end - 7200
        let labels = ["demo:build", "demo:test", "demo:lint"], peaks: [Int64] = [2600, 1500, 700]
        typealias Run = (k: Int, attempt: Int64, arrival: Int64, admitted: Int64, end: Int64)
        var runs: [Run] = []
        for k in 0..<15 {
            let arrival = start + 300 + Int64(k) * 440, wait = Int64(k % 3) * 50, ran = 200 + Int64(k % 4) * 70
            runs.append((k, 1, arrival, arrival + wait, arrival + wait + ran))
            if k == 5 { runs.append((k, 2, arrival + wait + ran + 3, arrival + wait + ran + 48, arrival + wait + ran + 308)) }
        }
        let ns = { (s: Int64) in s * 1_000_000_000 }
        var events: [String] = [], log: [String] = []
        for r in runs {
            let (label, peak, id) = (labels[r.k % 3], peaks[r.k % 3], "night-\(r.k)")
            var n = 0
            let line = { (t: Int64, e: String, extra: String) -> String in
                n += 1
                return #"{"v":1,"e":"\#(e)","run":"\#(id)","attempt":\#(r.attempt),"n":\#(n),"time_ns":\#(ns(t)),"label":"\#(label)"\#(extra)}"#
            }
            events.append(line(r.arrival, "enqueue", #","ticket":"t-\#(id)-\#(r.attempt)","typical_s":300,"real_memory":false,"need_mib":\#(peak)"#))
            let reason = r.attempt > 1 ? "restart_calm" : r.k % 2 == 0 ? "room_short" : "behind_head"
            for t in stride(from: r.arrival, to: r.admitted, by: 30) {
                events.append(line(t, "waiting", #","reason":"\#(reason)","room_mib":400"#))
            }
            events.append(line(r.admitted, "admitted", #","hold":"h-\#(id)-\#(r.attempt)""#))
            let stopped = r.k == 5 && r.attempt == 1, timedOut = r.k == 9
            let record = #"{"time_ns":\#(ns(r.arrival)),"label":"\#(label)","waited_s":\#(r.admitted - r.arrival),"ran_s":\#(r.end - r.admitted),"mem_peak_kib":\#(peak * 1024),"exit":\#(stopped ? 137 : 0),"fail_open":"\#(timedOut ? "timeout" : "")""#
            log.append(record + (stopped ? #","stops":1}"# : "}"))
            let marks = stopped ? #","stopped_by":"watchdog_red","signal":"KILL""# : timedOut ? #","fail_open":"timeout""# : ""
            events.append(line(r.end, "ended", #","hold":"h-\#(id)-\#(r.attempt)","record":\#(record)}\#(marks)"#))
        }
        events.append(#"{"v":1,"e":"memory","time_ns":\#(ns(end - 10)),"top":[{"name":"proc-1","footprint_mib":4885},{"name":"proc-2","footprint_mib":1508},{"name":"proc-3","footprint_mib":1323}],"vm":{"name":"proc-vm","footprint_mib":2210}}"#)
        var samples: [String] = []
        for t in stride(from: start, through: end, by: 2) where !(end - 4800..<end - 4440).contains(t) {
            if t == end - 3000 {
                samples.append(#"{"v":1,"time_ns":\#(ns(t)),"headroom_ok":false,"headroom_mib":0,"reserve_mib":256,"room_mib":0,"jobs":[]}"#)
                continue
            }
            let live = runs.filter { $0.admitted <= t && t < $0.end }
            let jobs = live.map { r -> (String, String, Int64, Int64) in
                let peak = peaks[r.k % 3]
                return ("h-night-\(r.k)-\(r.attempt)", labels[r.k % 3], peak * min(120, t - r.admitted) / 120, peak)
            }
            let outside = 6200 + Int64(800 * sin(Double(t) / 900))
            let held = jobs.reduce(0) { $0 + $1.2 }, growth = jobs.reduce(0) { $0 + $1.3 - $1.2 }
            let headroom = 16384 - outside - held
            let list = jobs.map { #"{"hold":"\#($0.0)","label":"\#($0.1)","footprint_mib":\#($0.2)}"# }.joined(separator: ",")
            samples.append(#"{"v":1,"time_ns":\#(ns(t)),"headroom_ok":true,"headroom_mib":\#(headroom),"reserve_mib":256,"room_mib":\#(headroom - 256 - growth),"jobs":[\#(list)]}"#)
        }
        for (file, lines) in [("telemetry/samples.jsonl", samples), ("telemetry/events.jsonl", events), ("log/runs.jsonl", log)] {
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appending(path: file))
        }
        return dir
    }

    /// The fixture's newest moment: its last line, or when its status document was read.
    private static func newest(status: Data, telemetry: URL) -> Date {
        var ns: Double = 0
        if let doc = try? StatusDocument.decode(status) {
            for h in doc.holds { ns = max(ns, Double(h.startNS) + h.heldForS * 1e9) }
            for t in doc.tickets { ns = max(ns, Double(t.createdNS) + t.waitedS * 1e9) }
            ns = max(ns, Double(doc.reconciledNS))
        }
        for log in ["telemetry/samples.jsonl", "telemetry/events.jsonl", "log/runs.jsonl"] {
            let text = (try? String(contentsOf: telemetry.appending(path: log), encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                if let t = (o?["time_ns"] as? NSNumber)?.doubleValue { ns = max(ns, t) }
            }
        }
        return Date(timeIntervalSince1970: ns / 1e9)
    }

    private static func fixturesDirectory(_ args: [String]) -> URL {
        if let dir = value("--fixtures-dir", args) { return URL(filePath: dir, directoryHint: .isDirectory) }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            if FileManager.default.fileExists(atPath: d.appending(path: "Package.swift").path) {
                return d.appending(path: "Tests/CoreslotKitTests/Fixtures", directoryHint: .isDirectory)
            }
            dir = d.deletingLastPathComponent()
        }
        fail("no Package.swift above the executable; pass --fixtures-dir DIR")
    }

    private static func value(_ flag: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count else { fail("\(flag) needs a value") }
        return args[i + 1]
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("coreslot-menubar: \(message)\n".utf8))
        exit(64)
    }

    private static let exit3: @Sendable (Data) -> RunResult = { RunResult(exitCode: 3, stdout: $0) }

    private static func level(_ level: String) -> @Sendable (inout [String: Any]) -> Void {
        { edit(&$0, "watch") { $0["level"] = level; $0["learning"] = 0 } }
    }

    /// Edits the object at `key`, or each object of the array at `key`.
    private nonisolated static func edit(_ raw: inout [String: Any], _ key: String, _ change: (inout [String: Any]) -> Void) {
        if var o = raw[key] as? [String: Any] {
            change(&o)
            raw[key] = o
        } else if var a = raw[key] as? [[String: Any]] {
            for i in a.indices { change(&a[i]) }
            raw[key] = a
        }
    }

    /// More running and waiting rows than the popover shows without scrolling.
    private nonisolated static func many(_ raw: inout [String: Any]) {
        let holds = raw["holds"] as! [[String: Any]], tickets = raw["tickets"] as! [[String: Any]]
        let base = holds[1]
        raw["holds"] = (0..<6).map { i -> [String: Any] in
            var h = base
            h["name"] = "0179450810285104000\(i)-0000092760-000004-demo_job\(i)"
            h["label"] = "demo:job\(i)"
            h["footprint_mib"] = 200 + i * 150
            h["need_mib"] = 400 + i * 150
            h["typical_s"] = 60 * (i + 1)
            h["left_s"] = i == 2 ? 0 : 30 * (i + 1)
            h["held_for_s"] = 30.0 * Double(i + 1)
            h["stoppable"] = i % 2 == 0
            return h
        }
        raw["tickets"] = (0..<7).map { i -> [String: Any] in
            var t = tickets[0]
            t["name"] = "0179450810285843400\(i)-0000092767-000001-demo_next\(i)"
            t["id"] = "0179450810285843400\(i)-0000092767-000001"
            t["label"] = "demo:next\(i)"
            t["position"] = i + 1
            t["waited_s"] = 90.0 - Double(i * 10)
            t["expected_wait_s"] = i == 0 ? 120 : NSNull()
            return t
        }
        edit(&raw, "mem") { $0["reserved_mib"] = 4650; $0["room_mib"] = 0; $0["free_mib"] = 0 }
    }
}

/// A fixture's pids are not this machine's: every hold reads as a process running the root
/// directory, which no check accepts, so nothing is ever signalled; or, unreadable, as none.
private struct FixtureInspector: ProcessInspector {
    static let root = FileID(URL(filePath: "/"))!
    let readable: Bool

    func facts(_ pid: pid_t) -> ProcessFacts? {
        readable ? ProcessFacts(executable: Self.root, startSeconds: 0, arguments: ["coreslot"]) : nil
    }
}

/// Every state of the menu bar icon, at its size and enlarged.
private struct IconBoard: View {
    private let states: [(String, IconState)] = [
        ("idle", .idle), ("running 0", .running(fill: 0)), ("running 1", .running(fill: 1)),
        ("running 2", .running(fill: 2)), ("running 3", .running(fill: 3)), ("running 4", .running(fill: 4)),
        ("waiting 0", .waiting(fill: 0)), ("waiting 2", .waiting(fill: 2)), ("waiting 4", .waiting(fill: 4)),
        ("pressure", .pressure), ("unavailable", .unavailable),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(states, id: \.0) { name, state in
                GridRow {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    Image(nsImage: MenuBarIcon.image(for: state))
                    Image(nsImage: MenuBarIcon.image(for: state)).resizable().interpolation(.high).frame(width: 72, height: 72)
                }
            }
        }
        .padding(20)
    }
}
#endif
