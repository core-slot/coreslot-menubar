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
        binary = CoreslotBinary(url: file, version: Version(0, 8, 0), protocolFormats: [2])
    }
}

/// The queue fixture's stoppable hold, `demo:long`, admitted at 1794508102 s.
private let longName = "01794508102851040000-0000092760-000004-demo_long"
private let longPID: pid_t = 92760
private let admittedS: Int64 = 1_794_508_102

private func status(_ change: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
    var doc = try Fixture.object("status-queue.json")
    var holds = doc["holds"] as! [[String: Any]]
    change(&holds)
    doc["holds"] = holds
    return try Fixture.encode(doc)
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
    ProcessFacts(executable: exe, startSeconds: startS, arguments: arguments)
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

    // Mutation: compare `facts.executable` and the binary by path; the symlink to the same file
    // is refused in `everythingCheckedSendsSIGTERMToThatPid`, red. Mutation: drop the executable
    // check; `/bin/ls` is ready, red.
    @Test func anotherExecutableIsRefused() async throws {
        let b = try Binary()
        let check = await prepareStop(
            holdName: longName, using: b.binary, runner: statusRunner(try status()),
            inspector: FakeInspector(facts(URL(filePath: "/bin/ls"))))
        #expect(check == .refused("the process runs another executable"))
    }

    // Mutation: drop the start-time check; the process that started 60 s after its hold (a reused
    // pid) is ready, red. Mutation: make it two-sided (`abs(start − admitted) <= 2`); the run that
    // queued for 8 s before its hold is refused, red.
    @Test(arguments: [
        (admittedS + 60, false), (admittedS + 3, false), (admittedS + 2, true), (admittedS - 8, true), (admittedS - 600, true),
    ] as [(Int64, Bool)])
    func theProcessMayNotStartAfterItsHold(_ startS: Int64, _ ready: Bool) async throws {
        let b = try Binary()
        let check = await prepareStop(
            holdName: longName, using: b.binary, runner: statusRunner(try status()),
            inspector: FakeInspector(facts(b.binary.url, startS: startS)))
        #expect(check == (ready ? .ready(pid: longPID, facts: facts(b.binary.url, startS: startS)) : .refused("the process started after its hold")))
    }

    // Mutation: treat unreadable facts as a pass (`?? facts(...)`); red.
    @Test func unreadableFactsAreRefused() async throws {
        let b = try Binary()
        let check = await prepareStop(holdName: longName, using: b.binary, runner: statusRunner(try status()), inspector: FakeInspector(nil))
        #expect(check == .refused("the process could not be read"))
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

    // Mutation: drop the range check in `canInspect`; pid 0 is asked and reads as checked, red.
    @Test func aHoldIsInspectableOnlyWhenItsProcessReads() throws {
        let hold = try #require(StatusDocument.decode(try status()).holds.first { $0.name == longName })
        let zero = try #require(StatusDocument.decode(try status { h in for i in h.indices { h[i]["pid"] = 0 } }).holds.first)
        #expect(canInspect(hold, inspector: FakeInspector(facts(URL(filePath: "/x")))))
        #expect(!canInspect(hold, inspector: FakeInspector(nil)))
        #expect(!canInspect(zero, inspector: FakeInspector(facts(URL(filePath: "/x")))))
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

@Suite struct AlertTextTests {
    private func hold() throws -> StatusDocument.Hold {
        try #require(StatusDocument.decode(Fixture.data("status-queue.json")).holds.first { $0.name == longName })
    }

    // Mutation: build the command line without `SafeText.display`; U+202E and U+2028 are applied, red.
    @Test func theCommandLineShowsHiddenCharactersEscaped() throws {
        let args = ["coreslot", "run", "--label", "build\u{202E}gpj.exe", "--", "make", "a\u{2028}b"]
        let alert = AlertText.stop(try hold(), pid: longPID, facts: facts(URL(filePath: "/x"), arguments: args))
        #expect(alert.message.contains(#"coreslot run --label build\u{202E}gpj.exe -- make a\u{2028}b"#))
        #expect(!alert.message.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{2028}" })
        #expect(alert.message.contains("It is not restarted") && alert.message.contains("Commands waiting behind it start as memory frees"))
        #expect(alert.title == "Stop demo:long?" && alert.confirm == "Stop")
    }

    // Mutation: cut at 2048; the whole line is shown, red.
    @Test func aLongCommandLineIsCutAt512() {
        let line = AlertText.commandLine([String(repeating: "x", count: 2000)])
        #expect(line.count == 513 && line.hasSuffix("…") && line.hasPrefix(String(repeating: "x", count: 512)))
        #expect(AlertText.commandLine(["a", "b"]) == "a b")
    }

    @Test func theRefusalSentences() {
        #expect(AlertText.refusal(.refused("x")) == "This process could not be confirmed as the command coreslot reports; nothing was sent.")
        #expect(AlertText.refusal(.gone) != nil && AlertText.refusal(.changed) != nil)
        #expect(AlertText.refusal(.ready(pid: 2, facts: facts(URL(filePath: "/x")))) == nil)
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
        var doc = try Fixture.object("status-queue.json")
        doc["tickets"] = (doc["tickets"] as! [[String: Any]]).filter { $0["id"] as? String != id }
        let after = try Fixture.encode(doc)
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
        #expect(f.executable.path == "/bin/cat")
        #expect(abs(f.startSeconds - Int64(Date().timeIntervalSince1970)) <= 5)
    }

    @Test func noProcessHasNoFacts() {
        #expect(DarwinProcessInspector().facts(0) == nil && DarwinProcessInspector().facts(-1) == nil)
        #expect(DarwinProcessInspector.parseProcArgs([2, 0, 0, 0, 0x2f, 0, 0x61, 0][...]) == nil)
    }
}
