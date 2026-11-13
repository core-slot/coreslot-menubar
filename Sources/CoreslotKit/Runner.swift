import Darwin
import Foundation
import Synchronization

public struct RunResult: Sendable, Equatable {
    /// The exit status; `128 + n` when signal `n` ended the process; nil when there is no such
    /// executable or it is not one (`ENOENT`, `EACCES`, `ENOEXEC`); `-errno` when it could not be
    /// started or waited for otherwise (`EMFILE`, say).
    public let exitCode: Int32?
    public let stdout: Data
    public let timedOut: Bool

    public init(exitCode: Int32?, stdout: Data = Data(), timedOut: Bool = false) {
        (self.exitCode, self.stdout, self.timedOut) = (exitCode, stdout, timedOut)
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

    /// A child process with stdin and stderr on /dev/null; past `timeout` it gets `SIGTERM`, then
    /// `SIGKILL` a second later, and is always reaped. Its stdout is read until a second past
    /// `timeout` at most, whatever the child did: a descendant that keeps the pipe open does not
    /// extend the run.
    public static let process = Runner { await spawn($0, $1, $2, $3, spawned: { _ in }) }

    /// Stdout keeps at most this much; the rest is read and dropped.
    static let outputLimit = 16 << 20

    static func spawn(
        _ exe: URL, _ args: [String], _ environment: [String: String]?, _ timeout: Duration,
        spawned: @Sendable (pid_t) -> Void
    ) async -> RunResult {
        var out: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return RunResult(exitCode: -errno) }
        var env = ProcessInfo.processInfo.environment
        env.merge(environment ?? [:]) { _, new in new }
        let (pid, error) = start(exe.path, [exe.path] + args, env.map { "\($0)=\($1)" }, stdout: out[1])
        close(out[1])
        guard error == 0 else {
            close(out[0])
            return RunResult(exitCode: [ENOENT, EACCES, ENOEXEC].contains(error) ? nil : -error)
        }
        spawned(pid)

        let child = Child(pid: pid), outRead = out[0], giveUp = ContinuousClock.now + timeout + .seconds(1)
        Task {
            try? await Task.sleep(for: timeout)
            guard child.signal(SIGTERM) else { return }
            try? await Task.sleep(for: .seconds(1))
            child.signal(SIGKILL)
        }
        return await withCheckedContinuation { (k: CheckedContinuation<RunResult, Never>) in
            let join = Join(child: child, continuation: k)
            Thread.detachNewThread { join.stdout(drain(outRead, until: giveUp)) }
            Thread.detachNewThread { join.exit(child.reap()) }
        }
    }

    /// posix_spawn with only stdin, stdout and stderr open in the child, and default signal handling.
    /// The pid, and 0 or the error posix_spawn returned.
    private static func start(_ path: String, _ argv: [String], _ envp: [String], stdout: Int32) -> (pid_t, Int32) {
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
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
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

    /// Reads `fd` to its end, or until `giveUp`.
    private static func drain(_ fd: Int32, until giveUp: ContinuousClock.Instant) -> Data {
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while ContinuousClock.now < giveUp {
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
}

/// The child and whether it has exited: no signal is sent once it has, so a reused pid is never hit.
private final class Child: Sendable {
    let pid: pid_t
    private let state = Mutex((exited: false, signalled: false))

    init(pid: pid_t) { self.pid = pid }

    /// Whether a signal was sent: only the timeout sends one.
    var timedOut: Bool { state.withLock { $0.signalled } }

    /// Sends `sig`; false when the child had already exited.
    @discardableResult func signal(_ sig: Int32) -> Bool {
        state.withLock {
            guard !$0.exited else { return false }
            $0.signalled = true
            kill(pid, sig)
            return true
        }
    }

    /// Waits for the exit without reaping, closes the door to signals, then reaps. The exit status,
    /// `128 + n` for signal `n`, or `-errno`.
    func reap() -> Int32 {
        var info = siginfo_t()
        var e: Int32 = 0
        repeat { e = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 ? 0 : errno } while e == EINTR
        state.withLock { $0.exited = true }
        while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
        if e != 0 { return -e }
        return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    }
}

/// Resumes the run's continuation once stdout is drained and the child is reaped.
private final class Join: Sendable {
    private let child: Child
    private let state: Mutex<(out: Data?, code: Int32?, k: CheckedContinuation<RunResult, Never>?)>

    init(child: Child, continuation: CheckedContinuation<RunResult, Never>) {
        self.child = child
        state = Mutex((nil, nil, continuation))
    }

    func stdout(_ d: Data) { finish { $0.out = d } }
    func exit(_ code: Int32) { finish { $0.code = code } }

    private func finish(_ set: (inout (out: Data?, code: Int32?, k: CheckedContinuation<RunResult, Never>?)) -> Void) {
        let done: (CheckedContinuation<RunResult, Never>, RunResult)? = state.withLock { s in
            set(&s)
            guard let out = s.out, let code = s.code, let k = s.k else { return nil }
            s.k = nil
            return (k, RunResult(exitCode: code, stdout: out, timedOut: child.timedOut))
        }
        if let (k, result) = done { k.resume(returning: result) }
    }
}
