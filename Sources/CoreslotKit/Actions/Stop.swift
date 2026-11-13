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

package enum StopCheck: Sendable, Equatable {
    case ready(pid: pid_t, facts: ProcessFacts)
    /// No live hold has the name: the command ended.
    case gone
    /// The hold is live but no longer stoppable.
    case changed
    /// Ready again after the confirmation, but for another pid or other facts than were shown.
    case differs(pid: pid_t, facts: ProcessFacts)
    /// The process could not be confirmed as the hold's; the reason is for the record, not shown.
    /// `pid` and `started`: the pid read and the start time of its facts, when they were.
    case refused(String, pid: pid_t? = nil, started: Int64? = nil)

    /// The pid this check read and its process's start time, each when read: a log line prints the two together.
    package var read: (pid: pid_t?, started: Int64?) {
        switch self { case .ready(let p, let f), .differs(let p, let f): (p, f.startSeconds); case .refused(_, let p, let s): (p, s); case .gone, .changed: (nil, nil) }
    }
}

/// How a stop ended; each carries the check that ended it.
package enum StopEnd: Sendable, Equatable {
    /// The first check did not pass: nothing was asked.
    case notAsked(StopCheck)
    /// The person was shown the `.ready` check and said no.
    case declined(StopCheck)
    /// Confirmed, but the check after it did not stand: nothing sent.
    case notSent(StopCheck)
    /// Confirmed and checked again; `SIGTERM` sent, or not, by the facts read right before it.
    case signalled(StopOutcome, StopCheck)
}

/// The order of a stop: check, ask about the process checked, check again, and only for the same
/// pid with the same facts as were shown, `sendStop`, which reads the facts once more. `ask` shows
/// the pid and facts and says whether the person confirmed.
package func stop(
    holdName: String, using binary: CoreslotBinary, runner: Runner, inspector: any ProcessInspector,
    ask: @Sendable (pid_t, ProcessFacts) async -> Bool, signal: (pid_t, Int32) -> Int32
) async -> StopEnd {
    let shown = await prepareStop(holdName: holdName, using: binary, runner: runner, inspector: inspector)
    guard case .ready(let pid, let facts) = shown else { return .notAsked(shown) }
    guard await ask(pid, facts) else { return .declined(shown) }
    let checked = await prepareStop(holdName: holdName, using: binary, runner: runner, inspector: inspector)
    let again = recheck(checked, shown: shown)
    guard case .ready = again else { return .notSent(again) }
    return .signalled(sendStop(again, inspector: inspector, signal: signal), again)
}

package enum StopOutcome: Sendable, Equatable {
    /// `changed`: nothing sent; `started`: the start time the facts read right before the signal give, when read.
    case sent, changed(started: Int64?), failed(Int32)
}

/// How much later than its hold's `start_ns` the process may have started. coreslot itself treats
/// a holder that started over 1 s after its hold as a reused pid; the start time's whole seconds
/// add one more. An earlier start is fine: a run that queued or restarted started before this hold.
let startSlackS: Int64 = 2

/// Reads `status` again and checks the hold's process; `.ready` only when every check passes.
package func prepareStop(
    holdName: String, using binary: CoreslotBinary, runner: Runner, inspector: any ProcessInspector
) async -> StopCheck {
    guard case .document(let doc, _) = await readStatus(binary, runner: runner) else {
        return .refused("status could not be read")
    }
    guard let hold = doc.holds.first(where: { $0.name == holdName }) else { return .gone }
    guard hold.stoppable == true else { return .changed }
    guard let pid = pid(of: hold) else { return .refused("pid \(hold.pid) is out of range") }
    guard let facts = inspector.facts(pid) else { return .refused("the process could not be read", pid: pid) }
    // A `coreslot run` started before coreslot was upgraded runs the old file: refused too.
    guard facts.executable == FileID(binary.url) else {
        return .refused("the process runs another executable", pid: pid, started: facts.startSeconds)
    }
    guard facts.startSeconds <= hold.startNS / 1_000_000_000 + startSlackS else {
        return .refused("the process started after its hold", pid: pid, started: facts.startSeconds)
    }
    return .ready(pid: pid, facts: facts)
}

/// Whether the hold's process can be read at all; status has no key for that, and when it cannot,
/// the hold's quiet line says so.
package func canInspect(_ hold: StatusDocument.Hold, inspector: any ProcessInspector) -> Bool {
    pid(of: hold).map { inspector.facts($0) != nil } ?? false
}

/// The hold's pid, when it can name a process other than the kernel and launchd.
private func pid(of hold: StatusDocument.Hold) -> pid_t? { (2...Int64(Int32.max)).contains(hold.pid) ? pid_t(hold.pid) : nil }

/// The check run again after the person confirmed `shown`: it stands only for the same pid with
/// the same facts, the command line they saw included; else `.differs`, with what it read.
package func recheck(_ again: StopCheck, shown: StopCheck) -> StopCheck {
    guard case .ready(let pid, let facts) = again, again != shown else { return again }
    return .differs(pid: pid, facts: facts)
}

/// `SIGTERM` to a `.ready` pid whose facts are still the ones checked; `signal` sends and returns
/// 0 or the errno.
package func sendStop(_ c: StopCheck, inspector: any ProcessInspector, signal: (pid_t, Int32) -> Int32) -> StopOutcome {
    guard case .ready(let pid, let facts) = c else { return .changed(started: nil) }
    let now = inspector.facts(pid)
    guard now == facts else { return .changed(started: now?.startSeconds) }
    let e = signal(pid, SIGTERM)
    return e == 0 ? .sent : .failed(e)
}
