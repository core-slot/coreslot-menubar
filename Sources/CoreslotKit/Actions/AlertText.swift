import Foundation

/// The words of the confirmations and of what follows them. Every string from coreslot or from a
/// process goes through `SafeText`.
public enum AlertText {
    public struct Alert: Sendable, Equatable {
        public let title: String
        public let message: String
        /// The button that acts; "Cancel" is the other one, and the default.
        public let confirm: String
    }

    /// How much of a command line the stop confirmation shows.
    static let commandLimit = 512

    /// The process's own arguments, each escaped, joined with spaces, cut at `commandLimit`. One
    /// that is empty or holds whitespace or a quote is quoted, so where each ends stays visible.
    public static func commandLine(_ arguments: [String]) -> String {
        let line = arguments.map(SafeText.display).map { a in
            a.isEmpty || a.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" }
                ? "\"" + a.replacingOccurrences(of: "\"", with: #"\""#) + "\"" : a
        }.joined(separator: " ")
        return line.count > commandLimit ? String(line.prefix(commandLimit)) + "…" : line
    }

    public static func stop(_ hold: StatusDocument.Hold, pid: pid_t, facts: ProcessFacts) -> Alert {
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

    public static func cancel(_ ticket: StatusDocument.Ticket) -> Alert {
        Alert(
            title: "Withdraw the request for \(SafeText.display(ticket.label))?",
            message: """
                It has waited \(Formatting.duration(ticket.waitedS)). \
                Its command does not start: coreslot run gives up with a refusal. \
                If it is admitted first, withdrawing has no effect.
                """,
            confirm: "Withdraw request")
    }

    /// Why nothing was sent; nil for `.ready`.
    public static func refusal(_ c: StopCheck) -> String? {
        switch c {
        case .ready: nil
        case .gone: "This command has already ended; nothing was sent."
        case .changed, .differs: "This command changed since it was shown; nothing was sent."
        case .refused: "This process could not be confirmed as the command coreslot reports; nothing was sent."
        }
    }

    /// What went wrong with the signal; nil when it was sent.
    public static func stopOutcome(_ o: StopOutcome) -> String? {
        switch o {
        case .sent: nil
        case .changed: refusal(.changed)
        case .failed(let e): "The stop signal could not be sent (system error \(e))."
        }
    }

    /// After a refused cancel, what `status` now says of the ticket, in neutral words.
    public static func cancelRefused(ticketID: String, now: StatusReading) -> String {
        guard case .document(let doc, _) = now else {
            return "coreslot did not withdraw the request, and its status cannot be read now."
        }
        return doc.tickets.contains { $0.id == ticketID && $0.live }
            ? "coreslot did not withdraw the request; it is still waiting."
            : "The request is no longer waiting, so there was nothing to withdraw."
    }

    public static func cancelFailed(_ p: Problem) -> String {
        switch p {
        case .notFound: "coreslot was not found; nothing was withdrawn."
        case .timedOut: "coreslot cancel did not answer in time; the request may still be waiting."
        case .failed(let code) where code < 0: "coreslot cancel could not be run (system error \(-code)); nothing was withdrawn."
        case .failed(let code): "coreslot cancel failed with exit status \(code); nothing was withdrawn."
        case .stateUnreadable, .malformed: "coreslot cancel failed; nothing was withdrawn."
        }
    }
}
