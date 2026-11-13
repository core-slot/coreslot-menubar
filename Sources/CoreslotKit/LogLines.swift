import Foundation

/// One line of the app's own log; text from the state directory in it has passed `SafeText.display`.
package struct LogLine: Equatable, Sendable {
    package let text: String
    package let failure: Bool

    package init(text: String, failure: Bool) { (self.text, self.failure) = (text, failure) }
}

/// What changed since the last time, as log lines: every poll is seen here, only changes come out.
package struct LogTransitions: Sendable {
    private var kind: Kind?
    private var notices: [String] = []
    private var binary: CoreslotBinary?
    private var readErrors: [String] = []

    package init() {}

    /// What a reading is, without its document: the log says when it changes.
    package enum Kind: Equatable, Sendable {
        case document, notices, problem(Problem)
        package init(_ r: StatusReading) {
            self = switch r { case .document: .document; case .notices: .notices; case .problem(let p): .problem(p) }
        }

        package var text: String {
            switch self { case .document: "document"; case .notices: "notices only"; case .problem(let p): "problem: " + Words.problem(p).state }
        }
    }

    /// A restart reads the record anew: the errors seen so far were of the record before.
    package mutating func restarted() { readErrors = [] }

    /// The reading's kind when it changes; notices as they appear or clear. A problem says nothing
    /// of notices, so they stand until the next reading that has them.
    package mutating func reading(_ r: StatusReading) -> [LogLine] {
        let now = Kind(r)
        defer { kind = now }
        let failure = if case .problem = now { true } else { false }
        let change = now == kind ? [] : [LogLine(text: "status: \(kind.map { "\($0.text) -> " } ?? "")\(now.text)", failure: failure)]
        let shown: [Notice]? = switch r {
        case .document(_, let n), .notices(let n): n
        case .problem: nil
        }
        guard let shown else { return change }
        return change + Self.diff(&notices, shown.map { Words.notice($0).log }, "notice:", "notice cleared:", failure: false)
    }

    /// The `coreslot` found, a new one, or none where there was one.
    package mutating func located(_ b: CoreslotBinary?) -> LogLine? {
        guard b != binary, let old = binary ?? b else { return nil }
        defer { binary = b }
        guard let b else { return LogLine(text: "coreslot lost at \(old.url.path)", failure: true) }
        return LogLine(text: "coreslot \(binary == nil ? "found" : "changed"): \(b.url.path), version \(b.version)", failure: false)
    }

    /// Errors reading the record, each once while it lasts, and once when it ends.
    package mutating func read(errors: [String]) -> [LogLine] {
        Self.diff(&readErrors, errors, "read error:", "read again:", failure: true)
    }

    /// Lines for what `new` adds to `old` and what it drops; `old` becomes `new`.
    private static func diff(_ old: inout [String], _ new: [String], _ added: String, _ dropped: String, failure: Bool) -> [LogLine] {
        defer { old = new }
        return new.filter { !old.contains($0) }.map { LogLine(text: "\(added) \($0)", failure: failure) }
            + old.filter { !new.contains($0) }.map { LogLine(text: "\(dropped) \($0)", failure: false) }
    }
}
