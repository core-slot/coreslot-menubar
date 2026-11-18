import Foundation
import Synchronization
import Testing
@testable import CoreslotKit

private let release = CoreslotBinary(url: URL(filePath: "/bin/sh"), version: Version(0, 9, 0))

private func reading(_ change: ((inout [String: Any]) -> Void)? = nil) throws -> DockerReading {
    interpretDocker(RunResult(exitCode: 0, stdout: try Fixture.data("docker-ok.json", change)))
}

/// Changes the `docker` object of the fixture.
private func docker(_ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
    { raw in
        var d = raw["docker"] as! [String: Any]
        change(&d)
        raw["docker"] = d
    }
}

@Suite struct DockerModelTests {
    // Mutation: drop the VM line's process part; red.
    @Test func theVMLineAndOneRowPerContainer() throws {
        let m = DockerModel(try reading())
        #expect(m.vm == "Docker VM 15.6 GiB · VM process 16.1 GiB · about 14.4 GiB free")
        #expect(m.rows.map(\.name) == ["ci-job-1", "shop-web-1", "shop-redis-1"])
        #expect(m.rows.map(\.detail) == ["ci/app:abc123", "shop-web · shop", "redis:7.4-alpine · shop"])
        #expect(m.rows[0].usage == "1.1 GiB of 4 GiB")
        #expect(m.rows[2].usage == "12 MiB of 15.6 GiB")
        #expect(m.note == nil)
    }

    // Mutation: show the footprint when `identified` is false; red.
    @Test func anUnidentifiedVMHasNoFootprint() throws {
        let m = DockerModel(try reading(docker { d in
            d["vm"] = ["mem_mib": 16009, "identified": false, "footprint_mib": 16494]
        }))
        #expect(m.vm == "Docker VM 15.6 GiB · about 14.4 GiB free")
    }

    // Mutation: say the reason of every state as the one of `no_reading`; red. `off` and
    // `not_running` are in the next test: nothing is drawn for them.
    @Test(arguments: [
        ("other_engine", "", "Another Docker engine is running: there is no Docker Desktop VM to show"),
        ("no_reading", "deadline", "Docker did not answer in time"),
        ("no_reading", "parse", "Docker's answer could not be read"),
        ("no_reading", "weird\u{7}", "Docker could not be read (weird\\u{0007})"),
        ("brand_new", "", "Docker state brand_new"),
    ])
    func otherStatesShowTheReason(_ state: String, _ reason: String, _ text: String) throws {
        let m = DockerModel(try reading(docker { d in
            d["state"] = state
            d["reason"] = reason
            d["vm"] = ["mem_mib": NSNull(), "identified": false, "footprint_mib": NSNull()]
            d["free_est_mib"] = NSNull()
            d["containers"] = [Any]()
        }))
        #expect(m.vm == nil && m.rows.isEmpty)
        #expect(m.note == text)
    }

    // Mutation: draw a note for `off` or `not_running`; a machine without Docker then carries a Docker line, red.
    @Test(arguments: [("not_running", ""), ("off", "config"), ("off", "remote-host")])
    func noDockerShowsNothing(_ state: String, _ reason: String) throws {
        let m = DockerModel(try reading(docker { d in
            d["state"] = state
            d["reason"] = reason
            d["vm"] = ["mem_mib": NSNull(), "identified": false, "footprint_mib": NSNull()]
            d["free_est_mib"] = NSNull()
            d["containers"] = [Any]()
        }))
        #expect(m.isEmpty)
    }

    // Mutation: show every container, or the first eight in the engine's order; red.
    @Test func onlyTheEightBiggestAreShown() throws {
        let m = DockerModel(try reading(docker { d in
            d["containers"] = (0..<12).map { i in
                ["id": String(repeating: "a", count: 64), "name": "c\(i)", "image": "img", "project": "", "usage_mib": i * 10, "limit_mib": 100] as [String: Any]
            }
        }))
        #expect(m.rows.map(\.name) == (4...11).reversed().map { "c\($0)" })
        #expect(m.more == "+4 more")
    }

    // Mutation: print an engine's strings unescaped; red.
    @Test func anEnginesStringsAreEscaped() throws {
        let m = DockerModel(try reading(docker { d in
            var c = (d["containers"] as! [[String: Any]])[0]
            c["name"] = "a\u{1b}[31mb"
            d["containers"] = [c]
        }))
        #expect(m.rows[0].name == "a\\u{001B}[31mb")
    }

    // Mutation: drop the note; an empty section draws a bare VM line, red.
    @Test func noContainersSaysSo() throws {
        let m = DockerModel(try reading(docker { $0["containers"] = [Any]() }))
        #expect(m.rows.isEmpty && m.note == "No containers running")
    }

    // Mutation: ignore config_warnings; red.
    @Test func configWarningsAreSaid() throws {
        let m = DockerModel(try reading { $0["config_warnings"] = ["[docker] enabled: not a boolean"] })
        #expect(m.warnings == ["[docker] enabled: not a boolean"])
    }

    // Mutation: draw a section for a reading never taken; red.
    @Test func nothingAskedShowsNothing() {
        #expect(DockerModel(nil).isEmpty)
    }

    // Mutation: name another command in the words; red.
    @Test func aProblemIsSaidInWords() {
        #expect(DockerModel(.problem(.timedOut)).note == "coreslot status --docker did not answer in time")
    }
}

@Suite struct DockerInterpretTests {
    // Mutation: branch on the exit code before decoding; exit 3 is then a state error, red.
    @Test func exit3WithADocumentIsStillAReading() throws {
        let data = try Fixture.data("docker-ok.json")
        guard case .section(let s) = interpretDocker(RunResult(exitCode: 3, stdout: data)) else {
            Issue.record("not a section")
            return
        }
        #expect(s.state == "ok" && s.containers.count == 3)
    }

    // Mutation: treat a document without `docker` as malformed; red.
    @Test func aDocumentWithoutTheKeyIsUnsupported() throws {
        let data = try Fixture.data("status-queue.json")
        #expect(interpretDocker(RunResult(exitCode: 0, stdout: data)) == .unsupported)
    }

    // Mutation: map a timeout to a failed exit, or a missing file to a timeout; red.
    @Test func failuresAreProblems() {
        #expect(interpretDocker(RunResult(exitCode: nil)) == .problem(.notFound))
        #expect(interpretDocker(RunResult(exitCode: 0, timedOut: true)) == .problem(.timedOut))
        #expect(interpretDocker(RunResult(exitCode: 70)) == .problem(.failed(exitCode: 70)))
        #expect(interpretDocker(RunResult(exitCode: 0, stdout: Data("{".utf8))) == .problem(.malformed))
    }
}

@Suite struct DockerSourceTests {
    private final class Calls: Sendable {
        let list = Mutex<[(URL, [String])]>([])
        var runner: Runner {
            Runner { exe, args, _, _ in
                self.list.withLock { $0.append((exe, args)) }
                return RunResult(exitCode: 0, stdout: try! Fixture.data("docker-ok.json"))
            }
        }
        var count: Int { list.withLock { $0.count } }
    }

    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    // Mutation: drop the 30 s check; the read at 10 s runs too, red.
    @Test func atMostOneReadPer30Seconds() async {
        let calls = Calls(), source = DockerSource(runner: calls.runner)
        #expect(await source.read(release, visible: true, at: at(0)) != nil)
        #expect(await source.read(release, visible: true, at: at(10)) == nil)
        #expect(await source.read(release, visible: true, at: at(29.9)) == nil)
        #expect(await source.read(release, visible: true, at: at(30)) != nil)
        #expect(calls.count == 2)
    }

    // Mutation: read while hidden; red. Mutation: count a hidden poll as a read, so the read on opening waits; red.
    @Test func onlyWhileTheWindowIsOpen() async {
        let calls = Calls(), source = DockerSource(runner: calls.runner)
        #expect(await source.read(release, visible: false, at: at(0)) == nil)
        #expect(await source.read(release, visible: false, at: at(100)) == nil)
        #expect(calls.count == 0)
        #expect(await source.read(release, visible: true, at: at(101)) != nil)
        #expect(calls.count == 1)
    }

    // Mutation: leave out `--docker`; red. The app runs coreslot alone: it needs no `docker` on its PATH.
    @Test func itRunsCoreslotWithTheFlagAndNothingElse() async {
        let calls = Calls(), source = DockerSource(runner: calls.runner)
        _ = await source.read(release, visible: true, at: at(0))
        let (exe, args) = calls.list.withLock { $0[0] }
        #expect(exe == release.url && args == ["status", "--json", "--docker"])
    }

    // Mutation: note the start after the run instead of before; two overlapping asks both run, red.
    @Test func aSlowReadIsNotRunTwice() async {
        let calls = Calls()
        let inner = calls.runner
        let slow = Runner { exe, args, env, t in
            try? await Task.sleep(for: .milliseconds(200))
            return await inner.run(exe, args, environment: env, timeout: t)
        }
        let source = DockerSource(runner: slow)
        async let a = source.read(release, visible: true, at: at(0))
        async let b = source.read(release, visible: true, at: at(1))
        let got = await [a, b]
        #expect(got.compactMap { $0 }.count == 1 && calls.count == 1)
    }
}

/// A coreslot that does not know `--docker` prints its usage on stderr, which the app does not
/// keep, and exits 64 with nothing on stdout. The app passes no argument that could earn a usage
/// error but that one.
@Suite struct DockerUnsupportedTests {
    private let usageError = RunResult(exitCode: 64)

    // Mutation: leave 64 to `.failed`; the section then shows a note, red.
    @Test func aUsageErrorIsUnsupportedAndShowsNothing() {
        #expect(interpretDocker(usageError) == .unsupported)
        #expect(DockerModel(.unsupported).isEmpty)
    }

    // Mutation: call every exit 64 unsupported even with a document on stdout; red.
    @Test func otherFailuresKeepTheirNote() throws {
        #expect(interpretDocker(RunResult(exitCode: 70)) == .problem(.failed(exitCode: 70)))
        #expect(interpretDocker(RunResult(exitCode: 0, timedOut: true)) == .problem(.timedOut))
        let data = try Fixture.data("docker-ok.json")
        guard case .section = interpretDocker(RunResult(exitCode: 64, stdout: data)) else {
            Issue.record("a document is a reading")
            return
        }
    }

    private func binary() throws -> (CoreslotBinary, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "coreslot-docker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        return (CoreslotBinary(url: url, version: Version(0, 8, 0)), url)
    }

    // Mutation: forget the refusal after one read; the next ask runs again, red.
    // Mutation: key the refusal on the path alone; a replaced file is never asked, red.
    @Test func itStopsAskingUntilTheBinaryChanges() async throws {
        let count = Mutex(0)
        let source = DockerSource(runner: Runner { _, _, _, _ in
            count.withLock { $0 += 1 }
            return RunResult(exitCode: 64)
        })
        let (bin, url) = try binary()
        defer { try? FileManager.default.removeItem(at: url) }
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(await source.read(bin, visible: true, at: t) == .unsupported)
        #expect(await source.read(bin, visible: true, at: t + 31) == nil)
        #expect(await source.read(bin, visible: true, at: t + 300) == nil)
        #expect(count.withLock { $0 } == 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: url.path)
        #expect(await source.read(bin, visible: true, at: t + 400) == .unsupported)
        #expect(count.withLock { $0 } == 2)
    }
}
