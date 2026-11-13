import Foundation
import Synchronization
import Testing
@testable import CoreslotKit

private let release = CoreslotBinary(url: URL(filePath: "/opt/coreslot"), version: Version(0, 8, 0))

@Suite struct InterpretTests {
    @Test func aDocumentWithExit0HasNoNotice() throws {
        let data = try Fixture.data("status-queue.json")
        let doc = try StatusDocument.decode(data)
        #expect(interpret(RunResult(exitCode: 0, stdout: data), binary: release) == .document(doc, []))
    }

    // Mutation: branch on the exit code before decoding (exit 3 is stateUnreadable); red.
    @Test func aDocumentWithExit3IsStillADocument() throws {
        let data = try Fixture.data("status-queue.json") { $0["config_error"] = "config.toml: line 2: bad value" }
        guard case .document(let doc, let notices) = interpret(RunResult(exitCode: 3, stdout: data), binary: release) else {
            Issue.record("not a document")
            return
        }
        #expect(notices == [.configError("config.toml: line 2: bad value")])
        #expect(doc.holds.count == 2 && doc.tickets.count == 2)
    }

    // Mutation: drop the degraded and format notices from `notices`; red.
    @Test func degradedAndAFormatNotUnderstoodAreNotices() throws {
        let data = try Fixture.data("status-queue.json") {
            $0["degraded"] = ["reason": "holds/ unreadable", "first_ns": 1, "count": 1, "malformed": false]
            $0["format_understood"] = false
            $0["format_error"] = "FORMAT: not a number"
        }
        #expect(interpret(RunResult(exitCode: 3, stdout: data), binary: release)
            == .document(try StatusDocument.decode(data), [.degraded("holds/ unreadable"), .formatNotUnderstood("FORMAT: not a number")]))
    }

    // Mutation: return .failed for every exit with no document; red.
    @Test func exit3WithNothingIsAStateError() {
        #expect(interpret(RunResult(exitCode: 3, stdout: Data("\n".utf8)), binary: release) == .problem(.stateUnreadable))
    }

    // Mutation: map every exit with no document to stateUnreadable; red.
    @Test func exit70WithNothingFailed() {
        #expect(interpret(RunResult(exitCode: 70), binary: release) == .problem(.failed(exitCode: 70)))
    }

    // Mutation: treat a stdout that does not decode as no stdout; red (it reads as .failed).
    @Test func aBrokenDocumentIsMalformed() {
        #expect(interpret(RunResult(exitCode: 0, stdout: Data("{".utf8)), binary: release) == .problem(.malformed))
    }

    // Mutation: drop the schema probe in StatusDocument.decode; the schema-2 document that decodes
    // is a document, and the one of another shape is .malformed, red.
    @Test func anotherSchemaIsNoticesOnly() throws {
        let decodable = try Fixture.data("status-queue.json") { $0["schema"] = 2 }
        for data in [decodable, Data(#"{"schema": 2, "queue": []}"#.utf8)] {
            #expect(interpret(RunResult(exitCode: 0, stdout: data), binary: release) == .notices([.schema(2)]))
        }
    }

    // Mutation: drop the too-old branch for a stdout that does not decode; it is .malformed, red.
    @Test func aCoreslotTooOldToDecodeIsTooOldNotMalformed() throws {
        let data = try Fixture.data("status-0.7.0.json") { $0["watch"] = nil; $0["mem"] = nil }
        let old = CoreslotBinary(url: release.url, version: Version(0, 3, 0))
        #expect(interpret(RunResult(exitCode: 0, stdout: data), binary: old) == .notices([.tooOld]))
        #expect(interpret(RunResult(exitCode: 0, stdout: data), binary: release) == .problem(.malformed))
    }

    // Mutation: drop the tooOld branch; red.
    @Test func anOlderCoreslotIsTooOld() throws {
        let data = try Fixture.data("status-0.7.0.json")
        let old = CoreslotBinary(url: release.url, version: Version(0, 7, 0))
        guard case .document(_, let notices) = interpret(RunResult(exitCode: 0, stdout: data), binary: old) else {
            Issue.record("not a document")
            return
        }
        #expect(notices == [.tooOld])
    }

    // Mutation: drop the isDevelopment check; a 0.0.0 build reads as too old, red.
    @Test func aDevelopmentBuildIsNotTooOld() throws {
        let data = try Fixture.data("status-queue.json")
        let dev = CoreslotBinary(url: release.url, version: .development)
        guard case .document(_, let notices) = interpret(RunResult(exitCode: 0, stdout: data), binary: dev) else {
            Issue.record("not a document")
            return
        }
        #expect(notices == [])
    }

    // Mutation: check timedOut after the document; a document cut short by the kill decodes as malformed, red.
    @Test func aTimeoutAndAMissingBinaryAreTheirOwnProblems() throws {
        let partial = try Fixture.data("status-queue.json").prefix(100)
        #expect(interpret(RunResult(exitCode: 143, stdout: partial, timedOut: true), binary: release) == .problem(.timedOut))
        #expect(interpret(RunResult(exitCode: nil), binary: release) == .problem(.notFound))
    }
}

/// A Runner that answers `status` from a list (the last answer repeats) and counts the runs it is
/// in; `version` answers with `version`'s line, counted apart.
private final class Scripted: Sendable {
    private let answers: Mutex<[RunResult]>
    private let delay: Duration
    let stats = Mutex((running: 0, most: 0, runs: 0))
    let version = Mutex((line: "coreslot 0.8.0 (protocol formats: 2)", runs: 0))

    init(_ answers: [RunResult], delay: Duration = .zero) {
        self.answers = Mutex(answers)
        self.delay = delay
    }

    var runner: Runner {
        Runner { _, args, _, _ in
            if args == ["version"] {
                return RunResult(exitCode: 0, stdout: Data(self.version.withLock { $0.runs += 1; return $0.line }.utf8))
            }
            #expect(args == ["status", "--json"])
            self.stats.withLock { $0.running += 1; $0.most = max($0.most, $0.running); $0.runs += 1 }
            try? await Task.sleep(for: self.delay)
            self.stats.withLock { $0.running -= 1 }
            return self.answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }
    }

    func source(find: @escaping @Sendable () -> URL? = { release.url }) -> StatusSource {
        StatusSource(find: find, environment: nil, runner: runner)
    }
}

/// The readings of a stream, collected as they come by a consumer task that is cancelled at the end.
private final class Collected: Sendable {
    let got = Mutex<[StatusReading]>([])

    func consume(_ stream: AsyncStream<Polled>) -> Task<Void, Never> {
        Task { for await p in stream { self.got.withLock { $0.append(p.reading) } } }
    }

    func waitFor(_ n: Int, within limit: Duration = .seconds(5)) async throws {
        try await waitUntil(limit) { got.withLock { $0.count } >= n }
    }
}

private func waitUntil(_ limit: Duration = .seconds(5), _ done: () -> Bool) async throws {
    let end = ContinuousClock.now + limit
    while !done() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
}

@Suite struct StatusSourceTests {
    // Mutation: end the loop after a reading that is a problem; the second never comes, red.
    @Test func aGoodReadingFollowsAFailedOne() async throws {
        let data = try Fixture.data("status-idle.json")
        let fake = Scripted([RunResult(exitCode: 70), RunResult(exitCode: 0, stdout: data)])
        let source = fake.source()
        await source.setInterval(.milliseconds(100))
        let got = Collected(), consumer = got.consume(source.readings())
        defer { consumer.cancel() }
        try await got.waitFor(2)
        #expect(got.got.withLock { Array($0.prefix(2)) } == [.problem(.failed(exitCode: 70)), .document(try StatusDocument.decode(data), [])])
    }

    // Mutation: readNow starts a run of its own instead of waking the loop; two run at once, red.
    @Test func readNowNeverOverlapsARunInFlight() async throws {
        let data = try Fixture.data("status-idle.json")
        let fake = Scripted([RunResult(exitCode: 0, stdout: data)], delay: .milliseconds(300))
        let source = fake.source()
        let got = Collected(), consumer = got.consume(source.readings())
        defer { consumer.cancel() }
        try await waitUntil { fake.stats.withLock { $0.runs } == 1 }
        for _ in 0..<5 { await source.readNow() }
        try await got.waitFor(2)
        consumer.cancel()
        let stats = fake.stats.withLock { $0 }
        #expect(got.got.withLock { $0.count } == 2 && stats.most == 1 && stats.runs == 2, "\(stats)")
    }

    // Mutation: setInterval does not wake the sleeping loop; the next reading waits 10 s, red.
    @Test func aShorterIntervalTakesEffectAtOnce() async throws {
        let data = try Fixture.data("status-idle.json")
        let fake = Scripted([RunResult(exitCode: 0, stdout: data)])
        let source = fake.source()
        let got = Collected(), consumer = got.consume(source.readings())
        defer { consumer.cancel() }
        try await got.waitFor(1)
        await source.setInterval(.milliseconds(50))
        try await got.waitFor(2, within: .seconds(2))
        #expect(got.got.withLock { $0.count } >= 2)
    }

    // The R1 case: the consumer of PR 5's store, which returns from its loop when coreslot is not
    // found and asks again, then leaves for good. Mutation: poll from a task of the source's own
    // that feeds the stream, as before (a loop that outlives its consumer); the loops left behind
    // go on looking for coreslot after the consumer is gone, red.
    @Test func oneLoopPollsAndItEndsWithItsConsumer() async throws {
        let data = try Fixture.data("status-idle.json")
        let fake = Scripted([RunResult(exitCode: 0, stdout: data)])
        let looks = Mutex(0)
        let source = fake.source { looks.withLock { $0 += 1; return $0 == 1 ? nil : release.url } }
        await source.setInterval(.milliseconds(50))
        let start = ContinuousClock.now
        let consumer = Task {
            for await p in source.readings() where p.reading == .problem(.notFound) { break }
            var n = 0
            for await p in source.readings() {
                if p.binary == nil { Issue.record("not found again") }
                n += 1
                if n == 20 { break }
            }
        }
        await consumer.value
        let (took, looked) = (ContinuousClock.now - start, looks.withLock { $0 })
        // One loop at 50 ms: 21 looks take a second at least.
        #expect(looked == 21 && took >= .milliseconds(950), "\(looked) looks in \(took)")
        try await Task.sleep(for: .milliseconds(500))
        #expect(looks.withLock { $0 } == looked, "polling went on without a consumer")
    }

    // Mutation: keep the version by path alone (drop `k.id == id`); the coreslot replaced at the same
    // path keeps 0.8.0, red. Mutation: read the version on every poll (no `known`); `version` runs
    // once per poll, red.
    @Test func theVersionIsReadAgainOnlyWhenTheFileChanges() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appending(path: "coreslot"), next = dir.appending(path: "coreslot.new")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        let fake = Scripted([RunResult(exitCode: 0, stdout: try Fixture.data("status-idle.json"))])
        let source = fake.source { exe }
        for _ in 0..<3 { #expect(await source.read().binary?.version == Version(0, 8, 0)) }
        #expect(fake.version.withLock { $0.runs } == 1)
        try Data("#!/bin/sh\n# 0.8.1\n".utf8).write(to: next)
        _ = try FileManager.default.replaceItemAt(exe, withItemAt: next)
        fake.version.withLock { $0.line = "coreslot 0.8.1 (protocol formats: 2)" }
        #expect(await source.read().binary?.version == Version(0, 8, 1))
        #expect(await source.read().binary?.version == Version(0, 8, 1))
        #expect(fake.version.withLock { $0.runs } == 2)
    }
}
