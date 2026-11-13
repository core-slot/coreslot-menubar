import Foundation

/// The words of the confirmations and of what follows them. Every string from coreslot or from a
/// process goes through `SafeText`.
package enum AlertText {
    package struct Alert: Sendable, Equatable {
        package let title: String
        package let message: String
        /// The button that acts; "Cancel" is the other one, and the default.
        package let confirm: String
    }

    /// How much of a command line the stop confirmation shows.
    static let commandLimit = 512

    /// The process's own arguments, each escaped, joined with spaces, cut at `commandLimit`. One
    /// that is empty or holds whitespace or a quote is quoted, so where each ends stays visible.
    static func commandLine(_ arguments: [String]) -> String {
        let line = arguments.map(SafeText.display).map { a in
            a.isEmpty || a.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" }
                ? "\"" + a.replacingOccurrences(of: "\"", with: #"\""#) + "\"" : a
        }.joined(separator: " ")
        return line.count > commandLimit ? String(line.prefix(commandLimit)) + "…" : line
    }

    package static func stop(_ hold: StatusDocument.Hold, pid: pid_t, facts: ProcessFacts) -> Alert {
        Alert(
            title: "Stop this command?",
            message: """
                \(commandLine(facts.arguments))

                coreslot reports it as \(SafeText.display(hold.label)), at pid \(pid). \
                It has run for \(Formatting.duration(hold.heldForS)). It is not restarted: \
                it ends as failed, and whoever started it decides what next. \
                Commands waiting behind it start as memory frees.
                """,
            confirm: "Stop")
    }

    package static func cancel(_ ticket: StatusDocument.Ticket) -> Alert {
        Alert(
            title: "Withdraw the request for \(SafeText.display(ticket.label))?",
            message: """
                It has waited \(Formatting.duration(ticket.waitedS)). \
                Its command does not start: coreslot run gives up with a refusal. \
                If it is admitted first, withdrawing has no effect.
                """,
            confirm: "Withdraw request")
    }

    private static let changed = "This command changed since it was shown; nothing was sent."

    /// Why nothing was sent, in the log's words and the person's, and whether the log marks it a
    /// failure: a hold that ended or changed is not one. Nil for `.ready`.
    package static func refusal(_ c: StopCheck) -> (log: String, alert: String, failure: Bool)? {
        switch c {
        case .ready: nil
        case .gone: ("the hold is gone", "This command has already ended; nothing was sent.", false)
        case .changed: ("the hold is no longer stoppable", changed, false)
        case .differs: ("the process differs from the one confirmed", changed, true)
        case .refused(let r, _, _): (r, "This process could not be confirmed as the command coreslot reports; nothing was sent.", true)
        }
    }

    /// What became of the signal, in the log's words, and the person's when it was not sent.
    package static func stopOutcome(_ o: StopOutcome) -> (log: String, alert: String?) {
        switch o {
        case .sent: ("sent", nil)
        case .changed: ("not sent, the process changed", changed)
        case .failed(let e): ("failed, errno \(e)", "The stop signal could not be sent (system error \(e)).")
        }
    }

    /// After a refused cancel, what `status` now says of the ticket, in neutral words.
    package static func cancelRefused(ticketID: String, now: StatusReading) -> String {
        guard case .document(let doc, _) = now else {
            return "coreslot did not withdraw the request, and its status cannot be read now."
        }
        return doc.tickets.contains { $0.id == ticketID && $0.live }
            ? "coreslot did not withdraw the request; it is still waiting."
            : "The request is no longer waiting, so there was nothing to withdraw."
    }

    /// `cancel` fails as not found, timed out or failed; the state is `Words.problem`'s.
    package static func cancelFailed(_ p: Problem) -> String {
        Words.problem(p, command: "cancel").state + (p == .timedOut ? "; the request may still be waiting." : "; nothing was withdrawn.")
    }
}
