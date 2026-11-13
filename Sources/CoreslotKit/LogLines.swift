import Foundation

/// One line of the app's own log; text from the state directory in it has passed `SafeText.display`.
public struct LogLine: Equatable, Sendable {
    public let text: String
    public let failure: Bool

    public init(text: String, failure: Bool) { (self.text, self.failure) = (text, failure) }
}

/// What changed since the last time, as log lines: every poll is seen here, only changes come out.
public struct LogTransitions: Sendable {
    private var kind: String?
    private var notices: [String] = []
    private var binary: CoreslotBinary?
    /// The read errors last logged; a restart clears them, since the record it reads may be another.
    public var readErrors: [String] = []

    public init() {}

    /// The reading's kind when it changes; notices as they appear or clear. A problem says nothing
    /// of notices, so they stand until the next reading that has them.
    public mutating func reading(_ r: StatusReading) -> [LogLine] {
        let now = Self.kind(r)
        defer { kind = now }
        let change = now == kind ? [] : [LogLine(text: "status: \(kind.map { "\($0) -> " } ?? "")\(now)", failure: now.hasPrefix("problem"))]
        let shown: [Notice]? = switch r {
        case .document(_, let n), .notices(let n): n
        case .problem: nil
        }
        guard let shown else { return change }
        return change + Self.diff(&notices, shown.map(Self.text), "notice:", "notice cleared:", failure: false)
    }

    /// The `coreslot` found, a new one, or none where there was one.
    public mutating func located(_ b: CoreslotBinary?) -> LogLine? {
        guard b != binary, let old = binary ?? b else { return nil }
        defer { binary = b }
        guard let b else { return LogLine(text: "coreslot lost at \(old.url.path)", failure: true) }
        return LogLine(text: "coreslot \(binary == nil ? "found" : "changed"): \(b.url.path), version \(b.version)", failure: false)
    }

    /// Errors reading the record, each once while it lasts, and once when it ends.
    public mutating func read(errors: [String]) -> [LogLine] {
        Self.diff(&readErrors, errors, "read error:", "read again:", failure: true)
    }

    /// Lines for what `new` adds to `old` and what it drops; `old` becomes `new`.
    private static func diff(_ old: inout [String], _ new: [String], _ added: String, _ dropped: String, failure: Bool) -> [LogLine] {
        defer { old = new }
        return new.filter { !old.contains($0) }.map { LogLine(text: "\(added) \($0)", failure: failure) }
            + old.filter { !new.contains($0) }.map { LogLine(text: "\(dropped) \($0)", failure: false) }
    }

    public static func kind(_ r: StatusReading) -> String {
        switch r {
        case .document: "document"
        case .notices(let n): "notices only (\(n.map(text).joined(separator: ", ")))"
        case .problem(.notFound): "problem: coreslot not found"
        case .problem(.stateUnreadable): "problem: state unreadable, exit 3"
        case .problem(.failed(let code)): "problem: exit \(code)"
        case .problem(.malformed): "problem: output not understood"
        case .problem(.timedOut): "problem: timed out"
        }
    }

    static func text(_ n: Notice) -> String {
        switch n {
        case .tooOld: "coreslot older than \(Version.minimum)"
        case .degraded(let reason): "degraded: " + SafeText.display(reason)
        case .formatNotUnderstood(let e): "format not understood: " + SafeText.display(e)
        case .configError(let e): "config error: " + SafeText.display(e)
        case .schema(let s): "schema \(s)"
        }
    }
}
