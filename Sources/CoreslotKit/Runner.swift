import Darwin
import Dispatch
import Foundation
import Synchronization

public struct RunResult: Sendable, Equatable {
    /// The exit status; `128 + n` when signal `n` ended the process; nil when there is no such
    /// executable or it is not one (`ENOENT`, `EACCES`, `ENOEXEC`); `-errno` when it could not be
    /// started or waited for otherwise (`EMFILE`, say).
    public let exitCode: Int32?
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool

    public init(exitCode: Int32?, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false) {
        (self.exitCode, self.stdout, self.stderr, self.timedOut) = (exitCode, stdout, stderr, timedOut)
    }
}

/// Runs an executable and collects what it printed. Tests give one of their own.
public struct Runner: Sendable {
    let body: @Sendable (URL, [String], [String: String]?, Duration) async -> RunResult

    public init(_ body: @escaping @Sendable (URL, [String], [String: String]?, Duration) async -> RunResult) {
        self.body = body
    }

    /// `environment` is laid over the app's own; nil passes the app's own unchanged.
    public func run(_ exe: URL, _ args: [String], environment: [String: String]?, timeout: Duration) async -> RunResult {
        await body(exe, args, environment, timeout)
    }

    /// A child process with stdin from /dev/null; past `timeout` it gets `SIGTERM`, then `SIGKILL`
    /// a second later, and is always reaped. Once a timed-out child is reaped, its output is read
    /// for under a second more: a descendant that keeps the pipes open does not extend the run.
    public static let process = Runner { await spawn($0, $1, $2, $3, spawned: { _ in }) }

    /// Each of stdout and stderr keeps at most this much; the rest is read and dropped.
    static let outputLimit = 16 << 20

    static func spawn(
        _ exe: URL, _ args: [String], _ environment: [String: String]?, _ timeout: Duration,
        spawned: @Sendable (pid_t) -> Void
    ) async -> RunResult {
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return RunResult(exitCode: -errno) }
        guard pipe(&err) == 0 else {
            let e = errno
            close(out[0]); close(out[1])
            return RunResult(exitCode: -e)
        }
        var env = ProcessInfo.processInfo.environment
        env.merge(environment ?? [:]) { _, new in new }
        let (pid, error) = start(exe.path, [exe.path] + args, env.map { "\($0)=\($1)" }, stdout: out[1], stderr: err[1])
        close(out[1]); close(err[1])
        guard error == 0 else {
            close(out[0]); close(err[0])
            return RunResult(exitCode: [ENOENT, EACCES, ENOEXEC].contains(error) ? nil : -error)
        }
        spawned(pid)

        let child = Child(pid: pid), outRead = out[0], errRead = err[0]
        let deadline = DispatchTime.now() + dispatchInterval(timeout)
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            guard child.timeOut() else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { _ = child.signal(SIGKILL) }
        }
        return await withCheckedContinuation { (k: CheckedContinuation<RunResult, Never>) in
            let join = Join(child: child, continuation: k)
            Thread.detachNewThread { join.stdout(drain(outRead, child)) }
            Thread.detachNewThread { join.stderr(drain(errRead, child)) }
            Thread.detachNewThread { join.exit(child.reap()) }
        }
    }

    /// posix_spawn with only stdin, stdout and stderr open in the child, and default signal handling.
    /// The pid, and 0 or the error posix_spawn returned.
    private static func start(_ path: String, _ argv: [String], _ envp: [String], stdout: Int32, stderr: Int32) -> (pid_t, Int32) {
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnvp = envp.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnvp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, path, &actions, &attr, cArgv, cEnvp)
        return (pid, error)
    }

    /// Reads `fd` to its end, or until the child gives up on its output.
    private static func drain(_ fd: Int32, _ child: Child) -> Data {
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while !child.givenUp {
            let polled = poll(&ready, 1, 100)
            if polled == 0 || (polled < 0 && errno == EINTR) { continue } // nothing within 100 ms
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: buffer[0..<min(n, outputLimit - data.count)])
            } else if n == 0 || errno != EINTR {
                return data
            }
        }
        return data
    }

    private static func dispatchInterval(_ d: Duration) -> DispatchTimeInterval {
        let (s, atto) = d.components
        guard s < Int64(Int.max / 1_000_000_000) - 1 else { return .never }
        return .nanoseconds(Int(max(0, s)) * 1_000_000_000 + Int(max(0, atto) / 1_000_000_000))
    }
}

/// The child and whether it has exited: no signal is sent once it has, so a reused pid is never hit.
private final class Child: Sendable {
    let pid: pid_t
    private let state = Mutex((exited: false, timedOut: false, giveUp: ContinuousClock.Instant?.none))

    init(pid: pid_t) { self.pid = pid }

    var timedOut: Bool { state.withLock { $0.timedOut } }
    /// True from 900 ms after a timed-out child exited: with a poll every 100 ms, its output is
    /// waited for under a second more.
    var givenUp: Bool { state.withLock { $0.giveUp.map { ContinuousClock.now >= $0 } ?? false } }

    /// Marks the run timed out and sends `SIGTERM`; false when the child had already exited.
    func timeOut() -> Bool {
        state.withLock {
            guard !$0.exited else { return false }
            $0.timedOut = true
            kill(pid, SIGTERM)
            return true
        }
    }

    func signal(_ sig: Int32) -> Bool {
        state.withLock {
            guard !$0.exited else { return false }
            kill(pid, sig)
            return true
        }
    }

    /// Waits for the exit without reaping, closes the door to signals, then reaps.
    func reap() -> Int32? {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        state.withLock {
            $0.exited = true
            if $0.timedOut { $0.giveUp = .now + .milliseconds(900) }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return -errno }
        }
        let low = status & 0x7f
        return low == 0 ? (status >> 8) & 0xff : 128 + low
    }
}

/// Resumes the run's continuation once both pipes are drained and the child is reaped.
private final class Join: Sendable {
    private let child: Child
    private let state: Mutex<(out: Data?, err: Data?, code: Int32??, k: CheckedContinuation<RunResult, Never>?)>

    init(child: Child, continuation: CheckedContinuation<RunResult, Never>) {
        self.child = child
        state = Mutex((nil, nil, nil, continuation))
    }

    func stdout(_ d: Data) { finish { $0.out = d } }
    func stderr(_ d: Data) { finish { $0.err = d } }
    func exit(_ code: Int32?) { finish { $0.code = .some(code) } }

    private func finish(_ set: (inout (out: Data?, err: Data?, code: Int32??, k: CheckedContinuation<RunResult, Never>?)) -> Void) {
        let done: (CheckedContinuation<RunResult, Never>, RunResult)? = state.withLock { s in
            set(&s)
            guard let out = s.out, let err = s.err, let code = s.code, let k = s.k else { return nil }
            s.k = nil
            return (k, RunResult(exitCode: code, stdout: out, stderr: err, timedOut: child.timedOut))
        }
        if let (k, result) = done { k.resume(returning: result) }
    }
}
