import Darwin
import Foundation
import Synchronization
import Testing
@testable import CoreslotKit

@Suite struct VersionTests {
    // Mutation: do not trim the line, so its newline stays; red.
    @Test func aReleaseLineParses() throws {
        let v = try #require(Version.parse(versionLine: "coreslot 0.8.0 (protocol formats: 2)\n"))
        #expect(v == Version(0, 8, 0) && !v.isDevelopment)
    }

    // Mutation: drop the 0.0.0 rule in Version.init; red.
    @Test func aBuildFromACheckoutIsDevelopment() throws {
        #expect(try #require(Version.parse(versionLine: "coreslot 0.0.0-dev (protocol formats: 2)")).isDevelopment)
    }

    // Mutation: drop the check that the format is a number; the line with `x` parses, red.
    // Mutation: drop `w.count == 5`; the line cut after `formats:` traps on `w[4]`, red (crash).
    @Test(arguments: ["", "coreslot", "coreslot 0.8 (protocol formats: 2)", "coreslot 0.8.0 (protocol formats:",
                      "coreslot 0.8.0 (protocol formats: )",
                      "coreslot 0.8.0 (protocol formats: 2, 3)", "coreslot 0.8.0 (protocol formats: x)",
                      "other 0.8.0 (protocol formats: 2)"])
    func anythingElseDoesNot(_ line: String) {
        #expect(Version.parse(versionLine: line) == nil)
    }

    // Mutation: order by `description`, as text; 0.10.0 sorts before 0.9.9, red.
    @Test func versionsOrderByNumber() {
        #expect(Version(0, 7, 0) < .minimum && !(Version(0, 8, 0) < .minimum) && Version(0, 10, 0) > Version(0, 9, 9))
    }
}

@Suite struct LocateTests {
    // Mutation: refuse a symlink in isExecutableFile (lstat instead of stat); red.
    @Test func aSymlinkToAnExecutableIsFoundPastANonExecutableFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first"), second = root.appending(path: "second")
        let real = root.appending(path: "real")
        for d in [first, second, real] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try write(first.appending(path: "coreslot"), mode: 0o644)
        try write(real.appending(path: "coreslot-0.8.0"), mode: 0o755)
        try FileManager.default.createSymbolicLink(
            at: second.appending(path: "coreslot"), withDestinationURL: real.appending(path: "coreslot-0.8.0"))

        let found = Locate.find(override: nil, directories: [first], path: "relative/bin::\(second.path)")
        #expect(found?.path == second.appending(path: "coreslot").path)
    }

    // Mutation: drop the regular-file check; a directory named coreslot is returned, red.
    @Test func theOverrideComesFirstAndADirectoryIsNoBinary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: "bin"), other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: dir.appending(path: "coreslot"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try write(other.appending(path: "coreslot"), mode: 0o755)
        let pick = root.appending(path: "mine")
        try write(pick, mode: 0o755)

        #expect(Locate.find(override: pick, directories: [dir, other], path: nil)?.path == pick.path)
        #expect(Locate.find(override: nil, directories: [dir, other], path: nil)?.path
            == other.appending(path: "coreslot").path)
        #expect(Locate.find(override: nil, directories: [dir], path: nil) == nil)
    }

    // Mutation: take the home from `$HOME`; it is not `/elsewhere`, red. Mutation: take an empty
    // override as one; `config.toml` in no directory, red.
    @Test func theConfigurationFileFollowsCoreslotsRule() throws {
        let home = String(cString: try #require(getpwuid(getuid())).pointee.pw_dir) + "/.config/coreslot/config.toml"
        #expect(Locate.configFile(environment: ["CORESLOT_STATE_DIR": "/s/", "HOME": "/elsewhere"]) == "/s/config.toml")
        #expect(Locate.configFile(environment: ["HOME": "/elsewhere"]) == home && Locate.configFile(environment: ["CORESLOT_STATE_DIR": ""]) == home)
    }

    private func write(_ url: URL, mode: Int) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

@Suite struct ProbeTests {
    // Mutation: parse as before this fix, the slice from the prefix to " (protocol formats: "; the
    // line with no version builds a reversed range and traps, red (crash).
    @Test(arguments: [
        ("coreslot 0.8.1 (protocol formats: 2)", Version(0, 8, 1)), ("coreslot (protocol formats: 2)", nil), ("", nil),
    ] as [(String, Version?)])
    func aBinaryIsWhatItsVersionLineSays(_ line: String, _ want: Version?) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appending(path: "coreslot")
        try Data(("#!/bin/sh\n" + (line.isEmpty ? "" : "echo '\(line)'\n")).utf8).write(to: exe) // "": prints nothing
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        #expect(await CoreslotBinary.probe(exe, environment: nil)?.version == want)
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "coreslot-menubar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct RunnerTests {
    // Mutation: send no SIGTERM; sleep then lives until the SIGKILL at 2 s, red.
    // Mutation: send no SIGKILL; the case that ignores SIGTERM runs its 30 s, red.
    // Mutation: wait for the pipe's EOF however long (drop the give-up); the leftover sleep, which
    // prints its pid and holds the pipe, keeps the third case 12 s, red.
    // Mutation: give up only on a child that was signalled (the rule before this one); the child
    // that exits at once leaves its sleep holding the pipe for 8 s, red.
    @Test(arguments: [
        (["/bin/sleep", "30"], true, 1750),
        (["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 30"], true, 3000),
        (["/bin/sh", "-c", "/bin/sleep 12 & echo $!; exec /bin/sleep 30"], true, 3000),
        (["/bin/sh", "-c", "/bin/sleep 8 & echo $!; exit 0"], false, 3000),
    ])
    func aTimeoutEndsTheRunAndReapsTheChild(_ command: [String], timedOut: Bool, withinMS: Int) async throws {
        let pid = Mutex<pid_t>(0)
        let clock = ContinuousClock()
        let started = clock.now
        let r = await Runner.spawn(URL(filePath: command[0]), Array(command.dropFirst()), nil, .seconds(1)) { p in
            pid.withLock { $0 = p }
        }
        let took = clock.now - started
        if let leftover = pid_t(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(leftover, SIGKILL)
        }
        #expect(r.timedOut == timedOut)
        #expect(took < .milliseconds(withinMS), "took \(took)")
        let child = pid.withLock { $0 }
        #expect(child > 0)
        // No process left at that pid, not even a zombie: kill(2) finds a zombie.
        // Mutation: drop the waitpid loop; the zombie stays, red.
        errno = 0
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    // Mutation: drop the 16 MiB bound; red.
    // Mutation: dup2 the stdout pipe onto stderr too; stdout starts with "err", red.
    @Test func stdoutIsBoundedAndStderrIsNotRead() async {
        let script = "echo err >&2; /usr/bin/head -c 20000000 /dev/zero; exit 3"
        let r = await Runner.process.run(URL(filePath: "/bin/sh"), ["-c", script], environment: nil, timeout: .seconds(20))
        #expect(!r.timedOut)
        #expect(r.exitCode == 3)
        #expect(r.stdout.count == 16 << 20 && r.stdout.first == 0)
    }

    // Mutation: ignore `environment` (pass the app's own alone); red.
    @Test func theEnvironmentIsLaidOverTheAppsOwn() async {
        let r = await Runner.process.run(
            URL(filePath: "/bin/sh"), ["-c", "printf '%s|%s' \"$CORESLOT_STATE_DIR\" \"${PATH:+set}\""],
            environment: ["CORESLOT_STATE_DIR": "/tmp/x"], timeout: .seconds(5))
        #expect(String(decoding: r.stdout, as: UTF8.self) == "/tmp/x|set")
        #expect(r.exitCode == 0)
    }

    // Mutation: return `si_status` alone for a signal, not 128 + it; red.
    @Test func aSignalIs128PlusItsNumber() async {
        let r = await Runner.process.run(URL(filePath: "/bin/sh"), ["-c", "kill -TERM $$"], environment: nil, timeout: .seconds(5))
        #expect(r.exitCode == 128 + SIGTERM && !r.timedOut)
    }

    // Mutation: report a failed posix_spawn as exit 127; red.
    @Test func aMissingExecutableHasNoExitCode() async {
        let r = await Runner.process.run(URL(filePath: "/nonexistent/coreslot"), [], environment: nil, timeout: .seconds(5))
        #expect(r.exitCode == nil && !r.timedOut)
    }

    // Mutation: map every failure to start to nil; the argument list too long reads as not found, red.
    @Test func onlyANonExecutableIsNotFoundAndAnotherFailureFails() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (plain, garbage) = (root.appending(path: "plain"), root.appending(path: "garbage"))
        try Data("#!/bin/sh\n".utf8).write(to: plain) // 0644: EACCES
        try Data("not a program".utf8).write(to: garbage)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: garbage.path) // ENOEXEC
        for url in [plain, garbage] {
            #expect(await Runner.process.run(url, [], environment: nil, timeout: .seconds(5)).exitCode == nil, "\(url.lastPathComponent)")
        }
        let long = await Runner.process.run(URL(filePath: "/bin/echo"), [String(repeating: "x", count: 2 << 20)], environment: nil, timeout: .seconds(5))
        #expect(long.exitCode == -E2BIG)
        #expect(interpret(long, binary: CoreslotBinary(url: plain, version: .minimum)) == .problem(.failed(exitCode: -E2BIG)))
    }
}
