import Foundation

package enum CancelOutcome: Sendable, Equatable {
    /// coreslot published the request; the ticket's owner finds it on its next poll.
    case requested
    /// Exit 75, which has several causes: `status` read again, to say what it now sees.
    case refused(StatusReading)
    case failed(Problem)
}

/// `coreslot cancel -- <id>`: the `--` keeps an id from the state directory from reading as a flag.
package func cancel(ticketID: String, using binary: CoreslotBinary, runner: Runner) async -> CancelOutcome {
    let r = await runner.run(binary.url, ["cancel", "--", ticketID], environment: nil, timeout: .seconds(5))
    if r.timedOut { return .failed(.timedOut) }
    switch r.exitCode {
    case 0: return .requested
    case 75:
        return .refused(await readStatus(binary, runner: runner))
    case nil: return .failed(.notFound)
    case let code?: return .failed(.failed(exitCode: code))
    }
}
