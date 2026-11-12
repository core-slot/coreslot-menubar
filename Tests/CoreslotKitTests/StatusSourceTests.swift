import Foundation
import Synchronization
import Testing
@testable import CoreslotKit

private let release = CoreslotBinary(url: URL(filePath: "/opt/coreslot"), version: Version(0, 8, 0), protocolFormats: [2])

private func with(_ name: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var doc = try Fixture.object(name)
    change(&doc)
    return try Fixture.encode(doc)
}

@Suite struct InterpretTests {
    @Test func aDocumentWithExit0HasNoNotice() throws {
        let data = try Fixture.data("status-queue.json")
        let doc = try StatusDocument.decode(data)
        #expect(interpret(RunResult(exitCode: 0, stdout: data), binary: release) == .document(doc, []))
    }

    // Mutation: branch on the exit code before decoding (exit 3 is stateUnreadable); red.
    @Test func aDocumentWithExit3IsStillADocument() throws {
        let data = try with("status-queue.json") { $0["config_error"] = "config.toml: line 2: bad value" }
        guard case .document(let doc, let notices) = interpret(RunResult(exitCode: 3, stdout: data), binary: release) else {
            Issue.record("not a document")
            return
        }
        #expect(notices == [.configError("config.toml: line 2: bad value")])
        #expect(doc.holds.count == 2 && doc.tickets.count == 2)
    }

    // Mutation: drop the degraded and format notices from `notices`; red.
    @Test func degradedAndAFormatNotUnderstoodAreNotices() throws {
        let data = try with("status-queue.json") {
            $0["degraded"] = ["reason": "holds/ unreadable", "first_ns": 1, "count": 1, "malformed": false]
            $0["format_understood"] = false
        }
        #expect(interpret(RunResult(exitCode: 3, stdout: data), binary: release)
            == .document(try StatusDocument.decode(data), [.degraded("holds/ unreadable"), .formatNotUnderstood]))
    }

    // Mutation: return .failed for every exit with no document; red.
    @Test func exit3WithNothingIsAStateError() {
        let r = RunResult(exitCode: 3, stdout: Data("\n".utf8), stderr: Data("coreslot: holds/ is not a directory\n".utf8))
        #expect(interpret(r, binary: release) == .problem(.stateUnreadable(stderr: "coreslot: holds/ is not a directory\n")))
    }

    // Mutation: map every exit with no document to stateUnreadable; red.
    @Test func exit70WithNothingFailed() {
        #expect(interpret(RunResult(exitCode: 70), binary: release) == .problem(.failed(exitCode: 70)))
    }

    // Mutation: treat a stdout that does not decode as no stdout; red (it reads as .failed).
    @Test func aBrokenDocumentIsMalformed() {
        #expect(interpret(RunResult(exitCode: 0, stdout: Data("{".utf8)), binary: release) == .problem(.malformed))
    }

    // Mutation: decode before the schema probe; the schema-2 document that decodes keeps its holds, red.
    // Mutation: drop the schema probe; the document of another shape is .malformed, red.
    @Test func anotherSchemaIsANoticeOnly() throws {
        let decodable = try with("status-queue.json") { $0["schema"] = 2 }
        for data in [decodable, Data(#"{"schema": 2, "queue": []}"#.utf8)] {
            #expect(interpret(RunResult(exitCode: 0, stdout: data), binary: release) == .document(.schemaOnly(2), [.schema(2)]))
        }
    }

    // Mutation: drop the too-old branch for a stdout that does not decode; it is .malformed, red.
    @Test func aCoreslotOlderThan04IsTooOldNotMalformed() throws {
        let data = try with("status-0.7.0.json") { $0["watch"] = nil; $0["mem"] = nil }
        let old = CoreslotBinary(url: release.url, version: Version(0, 3, 0))
        #expect(interpret(RunResult(exitCode: 0, stdout: data), binary: old) == .document(.schemaOnly(1), [.tooOld(old.version)]))
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
        #expect(notices == [.tooOld(Version(0, 7, 0))])
    }

    // Mutation: test `< .minimum` before isDevelopment; a 0.0.0 build reads as too old, red.
    @Test func aDevelopmentBuildSaysSo() throws {
        let data = try Fixture.data("status-queue.json")
        let dev = CoreslotBinary(url: release.url, version: .development)
        guard case .document(_, let notices) = interpret(RunResult(exitCode: 0, stdout: data), binary: dev) else {
            Issue.record("not a document")
            return
        }
        #expect(notices == [.development])
    }

    // Mutation: check timedOut after the document; a document cut short by the kill decodes as malformed, red.
    @Test func aTimeoutAndAMissingBinaryAreTheirOwnProblems() throws {
        let partial = try Fixture.data("status-queue.json").prefix(100)
        #expect(interpret(RunResult(exitCode: 143, stdout: partial, timedOut: true), binary: release) == .problem(.timedOut))
        #expect(interpret(RunResult(exitCode: nil), binary: release) == .problem(.notFound))
    }
}

/// A Runner that answers from a list (the last answer repeats) and counts the runs it is in.
private final class Scripted: Sendable {
    private let answers: Mutex<[RunResult]>
    private let delay: Duration
    let stats = Mutex((running: 0, most: 0, runs: 0))

    init(_ answers: [RunResult], delay: Duration = .zero) {
        self.answers = Mutex(answers)
        self.delay = delay
    }

    var runner: Runner {
        Runner { _, args, _, _ in
            #expect(args == ["status", "--json"])
            self.stats.withLock { $0.running += 1; $0.most = max($0.most, $0.running); $0.runs += 1 }
            try? await Task.sleep(for: self.delay)
            self.stats.withLock { $0.running -= 1 }
            return self.answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }
    }
}

private func first(_ n: Int, of stream: AsyncStream<StatusReading>, within limit: Duration) async -> [StatusReading] {
    await withTaskGroup(of: [StatusReading]?.self) { group in
        group.addTask {
            var got: [StatusReading] = []
            for await r in stream {
                got.append(r)
                if got.count == n { break }
            }
            return got
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let winner = await group.next() ?? nil
        group.cancelAll()
        return winner ?? []
    }
}

@Suite struct StatusSourceTests {
    // Mutation: end the loop after a reading that is a problem; the second never comes, red.
    @Test func aGoodReadingFollowsAFailedOne() async throws {
        let data = try Fixture.data("status-idle.json")
        let fake = Scripted([RunResult(exitCode: 70), RunResult(exitCode: 0, stdout: data)])
        let source = StatusSource(binary: release, environment: nil, runner: fake.runner)
        await source.setInterval(.milliseconds(100))
        let got = await first(2, of: await source.readings(), within: .seconds(5))
        #expect(got == [.problem(.failed(exitCode: 70)), .document(try StatusDocument.decode(data), [])])
    }

    // Mutation: readNow starts a run of its own instead of waking the loop; two run at once, red.
    @Test func readNowNeverOverlapsARunInFlight() async throws {
        let data = try Fixture.data("status-idle.json")
        let fake = Scripted([RunResult(exitCode: 0, stdout: data)], delay: .milliseconds(300))
        let source = StatusSource(binary: release, environment: nil, runner: fake.runner)
        let stream = await source.readings()
        while fake.stats.withLock({ $0.runs }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<5 { await source.readNow() }
        let got = await first(2, of: stream, within: .seconds(5))
        #expect(got.count == 2)
        let stats = fake.stats.withLock { $0 }
        #expect(stats.most == 1 && stats.runs == 2, "\(stats)")
    }

    // Mutation: setInterval does not wake the sleeping loop; the next reading waits 10 s, red.
    @Test func aShorterIntervalTakesEffectAtOnce() async throws {
        let data = try Fixture.data("status-idle.json")
        let fake = Scripted([RunResult(exitCode: 0, stdout: data)])
        let source = StatusSource(binary: release, environment: nil, runner: fake.runner)
        let stream = await source.readings()
        while fake.stats.withLock({ $0.runs }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await source.setInterval(.milliseconds(50))
        #expect(await first(2, of: stream, within: .seconds(2)).count == 2)
    }
}
