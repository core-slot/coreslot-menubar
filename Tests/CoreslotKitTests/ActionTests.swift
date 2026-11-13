import Darwin
import Foundation
import Synchronization
import Testing
@testable import CoreslotKit

/// A `coreslot` file of its own and a symlink to it: the same file by device and inode.
private struct Binary {
    let binary: CoreslotBinary
    let link: URL

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "coreslot")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        binary = CoreslotBinary(url: file, version: Version(0, 8, 0))
    }
}

/// The queue fixture's stoppable hold, `demo:long`, admitted at 1794508102 s.
private let longName = "01794508102851040000-0000092760-000004-demo_long"
private let longPID: pid_t = 92760
private let admittedS: Int64 = 1_794_508_102

private func status(_ change: @escaping (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
    try Fixture.data("status-queue.json") { doc in
        var holds = doc["holds"] as! [[String: Any]]
        change(&holds)
        doc["holds"] = holds
    }
}

/// Answers each run from `answer`, and keeps every argument list it was given.
private final class FakeRunner: Sendable {
    let calls = Mutex<[[String]]>([])
    let answer: @Sendable ([String]) -> RunResult

    init(_ answer: @escaping @Sendable ([String]) -> RunResult) { self.answer = answer }

    var runner: Runner {
        Runner { _, args, _, _ in
            self.calls.withLock { $0.append(args) }
            return self.answer(args)
        }
    }
}

private func statusRunner(_ data: Data) -> Runner { FakeRunner { _ in RunResult(exitCode: 0, stdout: data) }.runner }

/// Gives each answer in turn and then the last one again; counts the questions.
private final class FakeInspector: ProcessInspector {
    private let answers: Mutex<[ProcessFacts?]>
    let asked = Mutex<[pid_t]>([])

    init(_ answers: ProcessFacts?...) { self.answers = Mutex(answers) }

    func facts(_ pid: pid_t) -> ProcessFacts? {
        asked.withLock { $0.append(pid) }
        return answers.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? nil }
    }
}

private func facts(_ exe: URL, startS: Int64 = admittedS, arguments: [String] = ["coreslot", "run", "--", "sleep", "600"]) -> ProcessFacts {
    ProcessFacts(executable: FileID(exe)!, startSeconds: startS, arguments: arguments)
}

@Suite struct StopTests {
    // Mutation: return `.ready` for a missing hold (skip the lookup); nothing is gone, red.
    @Test func aHoldThatEndedIsGoneAndNothingIsSignalled() async throws {
        let b = try Binary()
        let data = try status { $0.removeAll { $0["name"] as? String == longName } }
        let inspector = FakeInspector(facts(b.link))
        let check = await prepareStop(holdName: longName, using: b.binary, runner: statusRunner(data), inspector: inspector)
        #expect(check == .gone)
        var sent: [pid_t] = []
        #expect(sendStop(check, inspector: inspector, signal: { pid, _ in sent.append(pid); return 0 }) == .changed)
        #expect(sent.isEmpty && inspector.asked.withLock { $0.isEmpty })
    }

    // Mutation: drop the `stoppable` guard; a hold status no longer offers to stop is ready, red.
    @Test func aHoldNoLongerStoppableChanged() async throws {
        let b = try Binary()
        let data = try status { h in for i in h.indices { h[i]["stoppable"] = false } }
        let check = await prepareStop(holdName: longName, using: b.binary, runner: statusRunner(data), inspector: FakeInspector(facts(b.link)))
        #expect(check == .changed)
    }

    // Mutation: drop the executable check; `/bin/ls` is ready, red. Mutation: refuse without the
    // start time read (`started:` dropped); the log would say `started unknown`, red.
    @Test func anotherExecutableIsRefused() async throws {
        let b = try Binary()
        let check = await prepareStop(
            holdName: longName, using: b.binary, runner: statusRunner(try status()),
            inspector: FakeInspector(facts(URL(filePath: "/bin/ls"))))
        #expect(check == .refused("the process runs another executable", started: admittedS) && check.started == admittedS)
    }

    // Mutation: drop the start-time check; the process that started 60 s after its hold (a reused
    // pid) is ready, red. Mutation: make it two-sided (`abs(start − admitted) <= 2`); the run that
    // queued for 8 s before its hold is refused, red. Mutation: refuse without the start time read,
    // which is the evidence for the refusal; red.
    @Test(arguments: [
        (admittedS + 60, false), (admittedS + 3, false), (admittedS + 2, true), (admittedS - 8, true), (admittedS - 600, true),
    ] as [(Int64, Bool)])
    func theProcessMayNotStartAfterItsHold(_ startS: Int64, _ ready: Bool) async throws {
        let b = try Binary()
        let check = await prepareStop(
            holdName: longName, using: b.binary, runner: statusRunner(try status()),
            inspector: FakeInspector(facts(b.binary.url, startS: startS)))
        #expect(check == (ready ? .ready(pid: longPID, facts: facts(b.binary.url, startS: startS)) : .refused("the process started after its hold", started: startS)))
        #expect(check.started == startS)
    }

    // Mutation: treat unreadable facts as a pass (`?? facts(...)`); red.
    @Test func unreadableFactsAreRefused() async throws {
        let b = try Binary()
        let check = await prepareStop(holdName: longName, using: b.binary, runner: statusRunner(try status()), inspector: FakeInspector(nil))
        #expect(check == .refused("the process could not be read") && check.started == nil)
    }

    // Mutation: widen the range to `0...`; pid 0 and 1 reach the inspector, which says yes, red.
    @Test(arguments: [Int64(0), 1, -5, Int64(Int32.max) + 1])
    func aPidOutOfRangeIsRefused(_ pid: Int64) async throws {
        let b = try Binary()
        let data = try status { h in for i in h.indices where h[i]["name"] as? String == longName { h[i]["pid"] = pid } }
        let inspector = FakeInspector(facts(b.link))
        let check = await prepareStop(holdName: longName, using: b.binary, runner: statusRunner(data), inspector: inspector)
        #expect(check == .refused("pid \(pid) is out of range"))
        #expect(inspector.asked.withLock { $0.isEmpty })
    }

    // Mutation: return `.ready` when `status` gives no document; red.
    @Test func noStatusIsRefused() async throws {
        let b = try Binary()
        let runner = FakeRunner { _ in RunResult(exitCode: 70) }.runner
        let check = await prepareStop(holdName: longName, using: b.binary, runner: runner, inspector: FakeInspector(facts(b.link)))
        #expect(check == .refused("status could not be read"))
    }

    // Mutation: drop the re-read in `sendStop`; the pid that now runs another program gets
    // SIGTERM, red.
    @Test func factsThatChangeBeforeTheSignalSendNothing() async throws {
        let b = try Binary()
        let inspector = FakeInspector(facts(b.link), facts(URL(filePath: "/bin/ls"), startS: admittedS + 30))
        let check = await prepareStop(holdName: longName, using: b.binary, runner: statusRunner(try status()), inspector: inspector)
        guard case .ready = check else { Issue.record("\(check)"); return }
        var sent: [pid_t] = []
        #expect(sendStop(check, inspector: inspector, signal: { pid, _ in sent.append(pid); return 0 }) == .changed)
        #expect(sent.isEmpty)
    }

    // Mutation: send SIGKILL in `sendStop`; red.
    @Test func everythingCheckedSendsSIGTERMToThatPid() async throws {
        let b = try Binary()
        let inspector = FakeInspector(facts(b.link))
        let check = await prepareStop(holdName: longName, using: b.binary, runner: statusRunner(try status()), inspector: inspector)
        #expect(check == .ready(pid: longPID, facts: facts(b.link)))
        var sent: [(pid_t, Int32)] = []
        #expect(sendStop(check, inspector: inspector, signal: { sent.append(($0, $1)); return 0 }) == .sent)
        #expect(sent.count == 1 && sent.first?.0 == longPID && sent.first?.1 == SIGTERM)
        #expect(sendStop(check, inspector: inspector, signal: { _, _ in ESRCH }) == .failed(ESRCH))
    }

    // Mutation: drop the range check in `pid(of:)`; pid 0 is asked and reads as checked, red.
    @Test func aHoldIsInspectableOnlyWhenItsProcessReads() throws {
        let hold = try #require(StatusDocument.decode(try status()).holds.first { $0.name == longName })
        let zero = try #require(StatusDocument.decode(try status { h in for i in h.indices { h[i]["pid"] = 0 } }).holds.first)
        #expect(canInspect(hold, inspector: FakeInspector(facts(URL(filePath: "/bin/ls")))))
        #expect(!canInspect(hold, inspector: FakeInspector(nil)))
        #expect(!canInspect(zero, inspector: FakeInspector(facts(URL(filePath: "/bin/ls")))))
    }

    // Mutation: `recheck` returns `again` whatever it is; the other command line passes, red.
    @Test func aRecheckStandsOnlyForTheCommandLineShown() throws {
        let b = try Binary()
        let shown = StopCheck.ready(pid: longPID, facts: facts(b.link))
        #expect(recheck(shown, shown: shown) == shown)
        #expect(recheck(.ready(pid: longPID, facts: facts(b.link, arguments: ["coreslot", "run", "--", "other"])), shown: shown) == .changed)
        #expect(recheck(.ready(pid: longPID + 1, facts: facts(b.link)), shown: shown) == .changed)
        #expect(recheck(.gone, shown: shown) == .gone)
    }
}

/// The confirmation and the signal of one stop, recorded.
private final class Click: Sendable {
    let answer: Bool
    /// Each question: the pid and facts shown, and how many `status` runs had been made by then.
    let asked = Mutex<[(pid_t, ProcessFacts, Int)]>([])
    let sent = Mutex<[(pid_t, Int32)]>([])

    init(_ answer: Bool) { self.answer = answer }

    func stop(_ b: Binary, _ runner: FakeRunner, _ inspector: FakeInspector) async -> StopEnd {
        await CoreslotKit.stop(
            holdName: longName, using: b.binary, runner: runner.runner, inspector: inspector,
            ask: { pid, facts in self.asked.withLock { $0.append((pid, facts, runner.calls.withLock { $0.count })) }; return self.answer },
            signal: { pid, sig in self.sent.withLock { $0.append((pid, sig)) }; return 0 })
    }

    var nothingSent: Bool { sent.withLock { $0.isEmpty } }
}

/// The R5 order: check, ask, check again, compare with what was shown, read the facts, send.
@Suite struct StopOrderTests {
    // Mutation: check again before asking (the second `prepareStop` above `ask`); the question
    // comes after two `status` runs, red. Mutation: skip the second check (`let checked = shown`);
    // one `status` run in all, red.
    @Test func everythingCheckedSendsOneSIGTERMToThePidShown() async throws {
        let b = try Binary()
        let (runner, click) = (FakeRunner { _ in RunResult(exitCode: 0, stdout: try! status()) }, Click(true))
        let end = await click.stop(b, runner, FakeInspector(facts(b.link)))
        #expect(end == .signalled(.sent, .ready(pid: longPID, facts: facts(b.link))))
        #expect(click.asked.withLock { $0.map { "\($0.0) \($0.1 == facts(b.link)) \($0.2)" } } == ["\(longPID) true 1"])
        #expect(runner.calls.withLock { $0.count } == 2)
        #expect(click.sent.withLock { $0.map { "\($0.0) \($0.1)" } } == ["\(longPID) \(SIGTERM)"])
    }

    // Mutation: send whatever the answer (drop `guard await ask`); red.
    @Test func aDeclinedConfirmationSendsNothing() async throws {
        let b = try Binary()
        let (runner, click) = (FakeRunner { _ in RunResult(exitCode: 0, stdout: try! status()) }, Click(false))
        #expect(await click.stop(b, runner, FakeInspector(facts(b.link))) == .declined(.ready(pid: longPID, facts: facts(b.link))))
        #expect(click.nothingSent && runner.calls.withLock { $0.count } == 1)
    }

    // The R5 mutation: `recheck → checked` (use the second check as it is, not compared with what
    // was shown); the process with another command line gets SIGTERM, red.
    @Test func factsThatChangeBetweenTheChecksSendNothing() async throws {
        let b = try Binary()
        let other = facts(b.link, arguments: ["coreslot", "run", "--", "rm", "-rf", "/tmp/x"])
        let click = Click(true)
        let end = await click.stop(b, FakeRunner { _ in RunResult(exitCode: 0, stdout: try! status()) }, FakeInspector(facts(b.link), other))
        #expect(end == .notSent(.ready(pid: longPID, facts: other), differs: true))
        #expect(click.nothingSent)
    }

    // The R5 mutation `recheck → checked` again: the hold now names another pid, which gets
    // SIGTERM, red.
    @Test func aPidThatChangesBetweenTheChecksGetsNothing() async throws {
        let b = try Binary()
        let moved = try status { h in for i in h.indices where h[i]["name"] as? String == longName { h[i]["pid"] = Int64(longPID) + 1 } }
        let runs = Mutex(0)
        let runner = FakeRunner { _ in RunResult(exitCode: 0, stdout: runs.withLock { $0 += 1; return $0 } == 1 ? try! status() : moved) }
        let click = Click(true)
        let end = await click.stop(b, runner, FakeInspector(facts(b.link)))
        #expect(end == .notSent(.ready(pid: longPID + 1, facts: facts(b.link)), differs: true))
        #expect(click.nothingSent)
    }

    // N3: refused at the second check, the end carries that check, with its start time, never the
    // first's. Mutation: `.notSent(shown, …)`; the start time is the first check's, red.
    @Test func aRefusalAtTheSecondCheckCarriesItsOwnStartTime() async throws {
        let b = try Binary()
        let click = Click(true)
        let end = await click.stop(b, FakeRunner { _ in RunResult(exitCode: 0, stdout: try! status()) },
                                   FakeInspector(facts(b.link), facts(b.link, startS: admittedS + 60)))
        #expect(end == .notSent(.refused("the process started after its hold", started: admittedS + 60), differs: false))
        guard case .notSent(let c, _) = end else { return }
        #expect(c.started == admittedS + 60 && click.nothingSent)
    }

    // N1: refused at the first check, nothing is asked and the end carries the start time read.
    // Mutation: refuse another executable without `started:`; red.
    @Test func aRefusalAtTheFirstCheckAsksNothing() async throws {
        let b = try Binary()
        let click = Click(true)
        let end = await click.stop(b, FakeRunner { _ in RunResult(exitCode: 0, stdout: try! status()) }, FakeInspector(facts(URL(filePath: "/bin/ls"))))
        #expect(end == .notAsked(.refused("the process runs another executable", started: admittedS)))
        #expect(click.asked.withLock { $0.isEmpty } && click.nothingSent)
    }

    // Mutation: signal the re-checked pid without `sendStop`'s last read of the facts; the process
    // that changed after the second check gets SIGTERM, red.
    @Test func factsThatChangeAfterTheSecondCheckSendNothing() async throws {
        let b = try Binary()
        let click = Click(true)
        let end = await click.stop(b, FakeRunner { _ in RunResult(exitCode: 0, stdout: try! status()) },
                                   FakeInspector(facts(b.link), facts(b.link), facts(URL(filePath: "/bin/ls"))))
        #expect(end == .signalled(.changed, .ready(pid: longPID, facts: facts(b.link))))
        #expect(click.nothingSent)
    }
}

@Suite struct AlertTextTests {
    private func hold() throws -> StatusDocument.Hold {
        try #require(StatusDocument.decode(Fixture.data("status-queue.json")).holds.first { $0.name == longName })
    }

    // Mutation: build the command line without `SafeText.display`; U+202E and U+2028 are applied, red.
    // Mutation: title the alert with the hold's label; the forger's word leads, red.
    @Test func theAlertLeadsWithTheCommandLineShownEscaped() throws {
        let args = ["coreslot", "run", "--label", "build\u{202E}gpj.exe", "--", "make", "a\u{2028}b"]
        let alert = AlertText.stop(try hold(), pid: longPID, facts: facts(URL(filePath: "/bin/ls"), arguments: args))
        #expect(alert.message.hasPrefix(#"coreslot run --label build\u{202E}gpj.exe -- make a\u{2028}b"# + "\n\ncoreslot reports it as demo:long, at pid 92760."))
        #expect(!alert.message.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{2028}" })
        #expect(alert.message.contains("It is not restarted") && alert.message.contains("Commands waiting behind it start as memory frees"))
        #expect(alert.title == "Stop this command?" && alert.confirm == "Stop")
    }

    // Mutation: join the arguments unquoted; `["a b"]` reads as `["a", "b"]`, red.
    @Test func argumentsThatHideTheirBoundariesAreQuoted() {
        #expect(AlertText.commandLine(["a b"]) == #""a b""# && AlertText.commandLine(["a", "b"]) == "a b")
        #expect(AlertText.commandLine(["sh", "-c", #"echo "it's""#, ""]) == #"sh -c "echo \"it's\"" """#)
    }

    // Mutation: cut at 2048; the whole line is shown, red.
    @Test func aLongCommandLineIsCutAt512() {
        let line = AlertText.commandLine([String(repeating: "x", count: 2000)])
        #expect(line.count == 513 && line.hasSuffix("…") && line.hasPrefix(String(repeating: "x", count: 512)))
        #expect(AlertText.commandLine(["a", "b"]) == "a b")
    }

    // `.refused` is also what a `coreslot run` started before an upgrade gets: it runs the old file.
    @Test func theRefusalSentences() {
        #expect(AlertText.refusal(.refused("x")) == "This process could not be confirmed as the command coreslot reports; nothing was sent.")
        #expect(AlertText.refusal(.gone) != nil && AlertText.refusal(.changed) != nil)
        #expect(AlertText.refusal(.ready(pid: 2, facts: facts(URL(filePath: "/bin/ls")))) == nil)
    }
}

@Suite struct CancelTests {
    private let id = "01794508102858434000-0000092767-000001"

    // Mutation: drop the `--`, which keeps an id from reading as a flag; the arguments differ, red.
    @Test func exit0IsRequested() async throws {
        let b = try Binary()
        let fake = FakeRunner { _ in RunResult(exitCode: 0) }
        #expect(await cancel(ticketID: id, using: b.binary, runner: fake.runner) == .requested)
        #expect(fake.calls.withLock { $0 } == [["cancel", "--", id]])
    }

    // Mutation: return `.failed(.failed(exitCode: 75))` for 75; no new reading, red.
    @Test func exit75ReadsStatusAgain() async throws {
        let b = try Binary()
        let after = try Fixture.data("status-queue.json") { doc in
            doc["tickets"] = (doc["tickets"] as! [[String: Any]]).filter { $0["id"] as? String != id }
        }
        let fake = FakeRunner { $0.first == "cancel" ? RunResult(exitCode: 75) : RunResult(exitCode: 0, stdout: after) }
        let outcome = await cancel(ticketID: id, using: b.binary, runner: fake.runner)
        #expect(outcome == .refused(interpret(RunResult(exitCode: 0, stdout: after), binary: b.binary)))
        #expect(fake.calls.withLock { $0.map { $0[0] } } == ["cancel", "status"])
        guard case .refused(let now) = outcome else { return }
        #expect(AlertText.cancelRefused(ticketID: id, now: now) == "The request is no longer waiting, so there was nothing to withdraw.")
    }

    // Mutation: treat every non-zero exit as refused; 70 reads status again, red.
    @Test func exit70Failed() async throws {
        let b = try Binary()
        let fake = FakeRunner { _ in RunResult(exitCode: 70) }
        #expect(await cancel(ticketID: id, using: b.binary, runner: fake.runner) == .failed(.failed(exitCode: 70)))
        #expect(fake.calls.withLock { $0.count } == 1)
    }
}

@Suite struct ProcessInspectorTests {
    // Mutation: skip the padding NULs after the exec path; the first argument reads empty, red.
    @Test func aChildOfOursHasItsOwnFacts() throws {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/cat")
        p.arguments = ["-", "a b", ""]
        p.standardInput = Pipe()
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        let f = try #require(DarwinProcessInspector().facts(p.processIdentifier))
        #expect(f.arguments == ["/bin/cat", "-", "a b", ""])
        #expect(f.executable == FileID(URL(filePath: "/bin/cat")))
        #expect(abs(f.startSeconds - Int64(Date().timeIntervalSince1970)) <= 5)
    }

    // The S1 case: a process started from a path, that path then a link to another file. Mutation:
    // take the executable as `proc_pidpath` names it and stat that; the link's target, red.
    @Test(arguments: [false, true])
    func theFileIsTheOneRunningNotTheOneAtItsPathNow(_ hardLink: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "facts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (server, other, source) = (dir.appending(path: "server"), dir.appending(path: "other"), dir.appending(path: "server.c"))
        // A sleeper of its own, which says when it has started: a copy of a system binary is killed
        // as it starts, outside the system, and a path relinked while it starts kills it too.
        try Data(#"#include <unistd.h>\#nint main(void) { write(1, "r", 1); sleep(30); return 0; }"#.utf8).write(to: source)
        try Data("other".utf8).write(to: other)
        try Process.run(URL(filePath: "/usr/bin/cc"), arguments: ["-o", server.path, source.path]).waitUntilExit()
        let (p, out) = (Process(), Pipe())
        (p.executableURL, p.standardOutput) = (server, out)
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        #expect(out.fileHandleForReading.readData(ofLength: 1) == Data("r".utf8))
        let running = try #require(FileID(server))
        try FileManager.default.removeItem(at: server)
        try hardLink ? FileManager.default.linkItem(at: other, to: server) : FileManager.default.createSymbolicLink(at: server, withDestinationURL: other)
        #expect(FileID(server) == FileID(other) && FileID(other) != running)
        #expect(DarwinProcessInspector().facts(p.processIdentifier)?.executable == running)
    }

    // The S3 case: perl's own facts until it execs, then none. Mutation: skip every NUL after the exec
    // path; the empty `argv[0]` is lost and the environment's first string reads as the last argument, red.
    @Test func anEmptyFirstArgumentLeavesTheFactsUnread() async throws {
        let p = Process()
        (p.executableURL, p.arguments, p.environment) = (URL(filePath: "/usr/bin/perl"), ["-e", #"exec {"/bin/sleep"} "", "30""#], ["PROBE_SECRET": "x"])
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        var shown: [String] = []
        for _ in 0..<100 {
            guard let f = DarwinProcessInspector().facts(p.processIdentifier) else { break }
            shown += f.arguments
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(DarwinProcessInspector().facts(p.processIdentifier) == nil && !shown.contains("PROBE_SECRET=x"))
    }

    @Test func noProcessHasNoFacts() {
        #expect(DarwinProcessInspector().facts(0) == nil && DarwinProcessInspector().facts(-1) == nil)
        #expect(DarwinProcessInspector.parseProcArgs([2, 0, 0, 0, 0x2f, 0, 0x61, 0][...]) == nil)
    }
}
