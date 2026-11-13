import Foundation

/// The runs of `events.jsonl`, one entry per attempt, joined by `(run, attempt)`: a restart is an
/// attempt of its own.
package struct Runs: Sendable {
    package struct Key: Hashable, Sendable {
        package let run: String
        package let attempt: Int64
    }

    package struct Attempt: Sendable, Equatable {
        package let key: Key
        package var label: String
        /// From the `enqueue` line.
        package var ticket: String?
        package var typicalS: Int64?
        package var realMemory = false
        package var needMiB: Int64?
        package var arrivalNS: Int64?
        /// The latest `waiting` line, by its line number, and when it was written.
        package var waiting: EventLine.Waiting?
        package var waitingNS: Int64?
        package var admittedNS: Int64?
        /// The `ended` line, or the line that ended the wait without a start.
        package var end: End?
        package var stoppedBy: String?
        package var failOpen: String?
        package var signal: String?
        /// The `ended` line's copy of the run-log line: the exit status and the peak.
        package var record: RunLogLine?
        var waitingN: Int64 = 0
    }

    /// A `waiting` line with no `ahead`: the reason the head of the queue gave at that moment.
    package struct Head: Sendable, Equatable {
        package let timeNS: Int64
        package let reason: String
        package let key: Key
    }

    /// A stretch of time over which the head of the queue gave one reason.
    package struct HeadReason: Sendable, Equatable {
        package let fromNS: Int64
        package let toNS: Int64
        package let reason: String
    }

    /// A head's line holds at most this long: a waiter writes one every 30 s.
    static let headLineNS: Int64 = 32_000_000_000

    package struct End: Sendable, Equatable {
        /// The event's name: `ended`, `cancelled`, `interrupted`, `refused`, `timeout`, `not_started`.
        package let event: String
        package let timeNS: Int64
    }

    package private(set) var attempts: [Key: Attempt] = [:]
    private(set) var byTicket: [String: Key] = [:]
    private var byHold: [String: Key] = [:]
    /// A pass-through runs inside its parent's grant and has no run-log line: no attempt of its own.
    private var passThroughs: Set<Key> = []
    /// In time order.
    package private(set) var heads: [Head] = []

    package init() {}

    package mutating func apply(_ e: EventLine) {
        let key = Key(run: e.run, attempt: e.attempt)
        if passThroughs.contains(key) || e.kind == .outside(passThrough: true) {
            if case .ended = e.kind { passThroughs.remove(key) } else { passThroughs.insert(key) }
            return
        }
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
        // It runs from here, unbudgeted: after `--on-timeout run`'s `timeout`, or a state error.
        case .outside: (a.admittedNS, a.end) = (e.timeNS, nil)
        case .other: break
        }
        attempts[key] = a
    }

    /// Drops the attempts that ended before `date`, and their tickets; live and waiting ones stay.
    package mutating func prune(endedBefore date: Date) {
        attempts = attempts.filter { $0.value.end.map { $0.timeNS >= date.nanosecondsSince1970 } ?? true }
        byTicket = byTicket.filter { attempts[$0.value] != nil }
        byHold = byHold.filter { attempts[$0.value] != nil }
        heads.removeAll { $0.timeNS < date.nanosecondsSince1970 - Self.headLineNS }
    }

    /// What the head of the queue gave as its reason, from `fromNS` to `toNS`: each head's line
    /// holds until the next one, the end of its attempt's wait, or `headLineNS`, whichever is first.
    /// Where no line holds, the record says nothing of why.
    package func headReasons(fromNS: Int64, toNS: Int64) -> [HeadReason] {
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
    package func waiting(ticketName: String) -> Attempt? {
        byTicket[ticketName].flatMap { attempts[$0] }
    }

    /// The attempt whose `admitted` line names this hold.
    package func running(holdName: String) -> Attempt? { byHold[holdName].flatMap { attempts[$0] } }
}

/// Whether the local record looks on, from the app's own clock: it never reads `config.toml`.
package enum RecordState: Sendable, Equatable {
    case on, looksOff, unknown

    /// `lastSample` is when the app last read a new sample line; `holdLiveSince` is since when
    /// every poll has seen a live hold.
    package init(now: Date, lastSample: Date?, holdLiveSince: Date?) {
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
