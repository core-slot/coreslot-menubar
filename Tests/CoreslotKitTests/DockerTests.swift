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
        #expect(m.vm == "Docker VM 15.6 GiB · VM process 16.1 GiB · about 13.5 GiB free")
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
        #expect(m.vm == "Docker VM 15.6 GiB · about 13.5 GiB free")
    }

    // Mutation: say the reason of every state as the one of `no_reading`; red.
    @Test(arguments: [
        ("not_running", "", "Docker Desktop is not running"),
        ("other_engine", "", "Another Docker engine is running: there is no Docker Desktop VM to show"),
        ("off", "config", "Docker reading is turned off in coreslot's configuration"),
        ("off", "platform", "Docker reading is not available on this platform"),
        ("off", "remote-host", "Docker reading is off: DOCKER_HOST points at a remote engine"),
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

    // Mutation: print an engine's strings unescaped; red.
    @Test func anEnginesStringsAreEscaped() throws {
        let m = DockerModel(try reading(docker { d in
            var c = (d["containers"] as! [[String: Any]])[0]
            c["name"] = "a\u{1b}[31mb"
            d["containers"] = [c]
        }))
        #expect(m.rows[0].name == "a\\u{001B}[31mb")
    }

    @Test func noContainersSaysSo() throws {
        let m = DockerModel(try reading(docker { $0["containers"] = [Any]() }))
        #expect(m.rows.isEmpty && m.note == "No containers running")
    }

    // Mutation: ignore config_warnings; red.
    @Test func configWarningsAreSaid() throws {
        let m = DockerModel(try reading { $0["config_warnings"] = ["[docker] enabled: not a boolean"] })
        #expect(m.warnings == ["[docker] enabled: not a boolean"])
    }

    @Test func nothingAskedShowsNothing() {
        #expect(DockerModel(nil).isEmpty)
        #expect(DockerModel(.absent).isEmpty)
    }

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
    @Test func aCoreslotWithoutTheKeyIsAbsent() throws {
        let data = try Fixture.data("status-queue.json")
        #expect(interpretDocker(RunResult(exitCode: 0, stdout: data)) == .absent)
    }

    @Test func failuresAreProblems() {
        #expect(interpretDocker(RunResult(exitCode: nil)) == .problem(.notFound))
        #expect(interpretDocker(RunResult(exitCode: 0, timedOut: true)) == .problem(.timedOut))
        #expect(interpretDocker(RunResult(exitCode: 64)) == .problem(.failed(exitCode: 64)))
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

    // Mutation: keep the last read through `reset`; red.
    @Test func resetAllowsAReadAtOnce() async {
        let calls = Calls(), source = DockerSource(runner: calls.runner)
        _ = await source.read(release, visible: true, at: at(0))
        await source.reset()
        #expect(await source.read(release, visible: true, at: at(1)) != nil)
    }
}
