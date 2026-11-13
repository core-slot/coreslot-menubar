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
        public var signal: String?
        /// The `ended` line's copy of the run-log line: the exit status and the peak.
        public var record: RunLogLine?
        var waitingN: Int64 = 0
    }

    /// A `waiting` line with no `ahead`: the reason the head of the queue gave at that moment.
    public struct Head: Sendable, Equatable {
        public let timeNS: Int64
        public let reason: String
        public let key: Key
    }

    /// A stretch of time over which the head of the queue gave one reason.
    public struct HeadReason: Sendable, Equatable {
        public let fromNS: Int64
        public let toNS: Int64
        public let reason: String
    }

    /// A head's line holds at most this long: a waiter writes one every 30 s.
    static let headLineNS: Int64 = 32_000_000_000

    public struct End: Sendable, Equatable {
        /// The event's name: `ended`, `cancelled`, `interrupted`, `refused`, `timeout`, `not_started`.
        public let event: String
        public let timeNS: Int64
    }

    public private(set) var attempts: [Key: Attempt] = [:]
    private(set) var byTicket: [String: Key] = [:]
    private var byHold: [String: Key] = [:]
    /// In time order.
    public private(set) var heads: [Head] = []

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
            if w.ahead == nil {
                let head = Head(timeNS: e.timeNS, reason: w.reason, key: key)
                heads.insert(head, at: heads.lastIndex { $0.timeNS <= e.timeNS }.map { $0 + 1 } ?? 0)
            }
        case .admitted(let hold):
            a.admittedNS = e.timeNS
            if let hold { byHold[hold] = key }
        case .ended(let d):
            a.end = End(event: "ended", timeNS: e.timeNS)
            (a.stoppedBy, a.failOpen, a.signal, a.record) = (d.stoppedBy, d.failOpen, d.signal, d.record)
        case .waitEnded(let name): a.end = End(event: name, timeNS: e.timeNS)
        case .other: break
        }
        attempts[key] = a
    }

    /// Drops the attempts that ended before `date`, and their tickets; live and waiting ones stay.
    public mutating func prune(endedBefore date: Date) {
        attempts = attempts.filter { $0.value.end.map { $0.timeNS >= date.nanosecondsSince1970 } ?? true }
        byTicket = byTicket.filter { attempts[$0.value] != nil }
        byHold = byHold.filter { attempts[$0.value] != nil }
        heads.removeAll { $0.timeNS < date.nanosecondsSince1970 - Self.headLineNS }
    }

    /// What the head of the queue gave as its reason, from `fromNS` to `toNS`: each head's line
    /// holds until the next one, the end of its attempt's wait, or `headLineNS`, whichever is first.
    /// Where no line holds, the record says nothing of why.
    public func headReasons(fromNS: Int64, toNS: Int64) -> [HeadReason] {
        var out: [HeadReason] = []
        for (i, h) in heads.enumerated() {
            let a = attempts[h.key]
            let ends = [i + 1 < heads.count ? heads[i + 1].timeNS : nil, a?.admittedNS, a?.end?.timeNS, h.timeNS + Self.headLineNS, toNS]
            let to = ends.compactMap { $0 }.filter { $0 >= h.timeNS }.min() ?? h.timeNS
            guard to > fromNS, h.timeNS < toNS else { continue }
            out.append(HeadReason(fromNS: max(h.timeNS, fromNS), toNS: to, reason: h.reason))
        }
        return out
    }

    /// The attempt whose `enqueue` line names this ticket file.
    public func waiting(ticketName: String) -> Attempt? {
        byTicket[ticketName].flatMap { attempts[$0] }
    }

    /// The attempt whose `admitted` line names this hold.
    public func running(holdName: String) -> Attempt? { byHold[holdName].flatMap { attempts[$0] } }
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
