import Foundation

/// The runs of `events.jsonl`, one entry per attempt, joined by `(run, attempt)`: a restart is an
/// attempt of its own.
public struct Runs: Sendable {
    public struct Key: Hashable, Sendable {
        public let run: String
        public let attempt: Int64
    }

    public struct Attempt: Sendable, Equatable {
        public let key: Key
        public var label: String
        /// From the `enqueue` line.
        public var ticket: String?
        public var typicalS: Int64?
        public var realMemory = false
        public var needMiB: Int64?
        public var arrivalNS: Int64?
        /// The latest `waiting` line, by its line number, and when it was written.
        public var waiting: EventLine.Waiting?
        public var waitingNS: Int64?
        public var admittedNS: Int64?
        /// The `ended` line, or the line that ended the wait without a start.
        public var end: End?
        public var stoppedBy: String?
        public var failOpen: String?
        var waitingN: Int64 = 0
    }

    public struct End: Sendable, Equatable {
        /// The event's name: `ended`, `cancelled`, `interrupted`, `refused`, `timeout`, `not_started`.
        public let event: String
        public let timeNS: Int64
    }

    public private(set) var attempts: [Key: Attempt] = [:]
    private(set) var byTicket: [String: Key] = [:]

    public init() {}

    public mutating func apply(_ e: EventLine) {
        let key = Key(run: e.run, attempt: e.attempt)
        var a = attempts[key] ?? Attempt(key: key, label: e.label)
        a.label = e.label
        switch e.kind {
        case .enqueue(let q):
            (a.ticket, a.typicalS, a.realMemory, a.needMiB) = (q.ticket, q.typicalS, q.realMemory, q.needMiB)
            a.arrivalNS = e.timeNS
            byTicket[q.ticket] = key
        case .waiting(let w):
            if a.waiting == nil || e.n > a.waitingN {
                (a.waiting, a.waitingNS, a.waitingN) = (w, e.timeNS, e.n)
            }
        case .admitted:
            a.admittedNS = e.timeNS
        case .ended(let d):
            a.end = End(event: "ended", timeNS: e.timeNS)
            (a.stoppedBy, a.failOpen) = (d.stoppedBy, d.failOpen)
        case .cancelled: a.end = End(event: "cancelled", timeNS: e.timeNS)
        case .interrupted: a.end = End(event: "interrupted", timeNS: e.timeNS)
        case .refused: a.end = End(event: "refused", timeNS: e.timeNS)
        case .timeout: a.end = End(event: "timeout", timeNS: e.timeNS)
        case .notStarted: a.end = End(event: "not_started", timeNS: e.timeNS)
        case .stopped, .outside, .other: break
        }
        attempts[key] = a
    }

    /// Drops the attempts that ended before `date`, and their tickets; live and waiting ones stay.
    public mutating func prune(endedBefore date: Date) {
        attempts = attempts.filter { $0.value.end.map { $0.timeNS >= date.nanosecondsSince1970 } ?? true }
        byTicket = byTicket.filter { attempts[$0.value] != nil }
    }

    /// The attempt whose `enqueue` line names this ticket file.
    public func waiting(ticketName: String) -> Attempt? {
        byTicket[ticketName].flatMap { attempts[$0] }
    }
}

/// Whether the local record looks on, from the app's own clock: it never reads `config.toml`.
public enum RecordState: Sendable, Equatable {
    case on, looksOff, unknown

    /// `lastSample` is when the app last read a new sample line; `holdLiveSince` is since when
    /// every poll has seen a live hold.
    public init(now: Date, lastSample: Date?, holdLiveSince: Date?) {
        let sampleAge = lastSample.map { now.timeIntervalSince($0) }
        if let sampleAge, sampleAge <= 30 {
            self = .on
        } else if let since = holdLiveSince, now.timeIntervalSince(since) >= 60, (sampleAge ?? .infinity) > 60 {
            self = .looksOff
        } else {
            self = .unknown
        }
    }
}
