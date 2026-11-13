import Darwin
import Foundation

// The process checks before a stop. Adversary: an agent confined from signalling other processes
// but able to write the state directory, and perhaps the directory a victim was started from,
// which can forge a live hold naming any pid, with any `start_ns`. Anchors: the file the process
// at that pid runs, by the device and inode of its mapped executable, which no writer of the state
// directory or of the victim's directory can change (a path can be relinked, the mapping cannot);
// its start time, which that agent cannot change for another process; and the process's own
// command line, shown to the person before anything is sent. `start_ns` is the state directory's
// word, so the start check guards against a reused pid under an honest hold; against a forged
// hold the executable and the command line are what count. On any doubt nothing is sent.

public enum StopCheck: Sendable, Equatable {
    case ready(pid: pid_t, facts: ProcessFacts)
    /// No live hold has the name: the command ended.
    case gone
    /// The hold is live but no longer stoppable.
    case changed
    /// The process could not be confirmed as the hold's; the reason is for the record, not shown.
    case refused(String)
}

public enum StopOutcome: Sendable, Equatable {
    case sent, changed, failed(Int32)
}

/// How much later than its hold's `start_ns` the process may have started. coreslot itself treats
/// a holder that started over 1 s after its hold as a reused pid; the start time's whole seconds
/// add one more. An earlier start is fine: a run that queued or restarted started before this hold.
let startSlackS: Int64 = 2

/// Reads `status` again and checks the hold's process; `.ready` only when every check passes.
public func prepareStop(
    holdName: String, using binary: CoreslotBinary, runner: Runner, inspector: any ProcessInspector
) async -> StopCheck {
    let r = await runner.run(binary.url, ["status", "--json"], environment: nil, timeout: StatusSource.statusTimeout)
    guard case .document(let doc, _) = interpret(r, binary: binary) else {
        return .refused("status could not be read")
    }
    guard let hold = doc.holds.first(where: { $0.name == holdName }) else { return .gone }
    guard hold.stoppable == true else { return .changed }
    guard let pid = pid(of: hold) else { return .refused("pid \(hold.pid) is out of range") }
    guard let facts = inspector.facts(pid) else { return .refused("the process could not be read") }
    // A `coreslot run` started before coreslot was upgraded runs the old file: refused too.
    guard facts.executable == FileID(binary.url) else {
        return .refused("the process runs another executable")
    }
    guard facts.startSeconds <= hold.startNS / 1_000_000_000 + startSlackS else {
        return .refused("the process started after its hold")
    }
    return .ready(pid: pid, facts: facts)
}

/// Whether the hold's process can be read at all; status has no key for that, and when it cannot,
/// the hold's quiet line says so.
public func canInspect(_ hold: StatusDocument.Hold, inspector: any ProcessInspector) -> Bool {
    pid(of: hold).map { inspector.facts($0) != nil } ?? false
}

/// The hold's pid, when it can name a process other than the kernel and launchd.
private func pid(of hold: StatusDocument.Hold) -> pid_t? { (2...Int64(Int32.max)).contains(hold.pid) ? pid_t(hold.pid) : nil }

/// The check run again after the person confirmed `shown`: it stands only for the same pid with
/// the same facts, the command line they saw included.
public func recheck(_ again: StopCheck, shown: StopCheck) -> StopCheck {
    guard case .ready = again else { return again }
    return again == shown ? again : .changed
}

/// `SIGTERM` to a `.ready` pid whose facts are still the ones checked; `signal` sends and returns
/// 0 or the errno.
public func sendStop(_ c: StopCheck, inspector: any ProcessInspector, signal: (pid_t, Int32) -> Int32) -> StopOutcome {
    guard case .ready(let pid, let facts) = c, inspector.facts(pid) == facts else { return .changed }
    let e = signal(pid, SIGTERM)
    return e == 0 ? .sent : .failed(e)
}
