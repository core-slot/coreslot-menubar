#if DEBUG
import AppKit
import CoreslotKit
import SwiftUI

/// Debug-only launch flags. `--fixture NAME` runs the whole app over a recorded state;
/// `--present NAME[,NAME…]|all [--appearance light|dark]` opens the popover's content over each in
/// an ordinary window and prints `present-window <kind> <name> <window number>` per window, then
/// `present-ready`. `--fixtures-dir DIR` names the fixtures; by default they are found from the
/// executable up to `Package.swift`.
@MainActor
enum Present {
    struct Variant: Sendable {
        let name: String
        var fixture = "queue"
        var version = Version(0, 8, 0)
        var record: RecordState?
        var change: (@Sendable (inout [String: Any]) -> Void)?
        var result: (@Sendable (Data) -> RunResult)?

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
        .init(name: "state-unreadable", result: { _ in RunResult(exitCode: 3, stderr: Data("state directory: permission denied\n".utf8)) }),
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
    ]

    static func runIfAsked(_ args: [String]) -> Bool {
        guard let list = value("--present", args) else { return false }
        let fixtures = fixturesDirectory(args)
        let chosen = list == "all" ? variants.map(\.name) + ["icons"] : list.split(separator: ",").map(String.init)
        for name in chosen where name != "icons" && !variants.contains(where: { $0.name == name }) {
            fail("no variant \(name); the variants are \(variants.map(\.name).joined(separator: ", ")), icons and all")
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
                let store = Store(feed: feed(variants.first { $0.name == name }!, fixtures: fixtures, live: false))
                await store.readOnce()
                show(PopoverView(store: store, openTimeline: {}).environment(\.revealsRowActions, true), kind: "popover", name: name, at: i)
            }
            try? await Task.sleep(for: .milliseconds(500))
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

    private static var windows: [NSWindow] = []

    private static func show(_ view: some View, kind: String, name: String, at index: Int) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
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
        let telemetry = fixtures.appending(path: "telemetry-\(v.telemetry)", directoryHint: .isDirectory)
        let then = newest(status: original, telemetry: telemetry)
        let launched = Date()
        let binary = CoreslotBinary(url: URL(filePath: "/fixture/coreslot"), version: v.version, protocolFormats: [2])
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
        let locate: @Sendable () async -> CoreslotBinary? = { found ? binary : nil }
        return Feed(locate: locate, runner: runner, stateDir: telemetry, clock: clock, record: v.record)
    }

    /// The fixture's newest moment: its last line, or when its status document was read.
    private static func newest(status: Data, telemetry: URL) -> Date {
        var ns: Int64 = 0
        if let doc = try? StatusDocument.decode(status) {
            for h in doc.holds { ns = max(ns, h.startNS + Int64(h.heldForS * 1e9)) }
            for t in doc.tickets { ns = max(ns, t.createdNS + Int64(t.waitedS * 1e9)) }
            ns = max(ns, doc.reconciledNS)
        }
        for log in ["telemetry/samples.jsonl", "telemetry/events.jsonl", "log/runs.jsonl"] {
            let text = (try? String(contentsOf: telemetry.appending(path: log), encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                if let t = (o?["time_ns"] as? NSNumber)?.int64Value { ns = max(ns, t) }
            }
        }
        return Date(timeIntervalSince1970: Double(ns) / 1e9)
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
