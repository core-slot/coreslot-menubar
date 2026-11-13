import Darwin
import Foundation
import Testing
@testable import CoreslotKit

/// A log and its older generation in a directory of their own.
struct LogFiles {
    let root: URL
    var current: URL { root.appending(path: "samples.jsonl") }
    var older: URL { root.appending(path: "samples.1.jsonl") }

    init() throws { root = try temporaryDirectory() }

    func append(_ s: String, to url: URL? = nil) throws {
        let url = url ?? current
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(s.utf8))
    }

    func tail() -> JSONLTail { JSONLTail(current: current, older: older) }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

extension Fixture {
    static var telemetryNames: [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return all.filter { $0.hasPrefix("telemetry-") }.sorted()
    }
}

extension JSONLTail {
    /// Every line there is now, as text.
    mutating func drain(maxBytes: Int = 1 << 20) throws -> [String] {
        var all: [String] = []
        repeat { all += try read(maxBytes: maxBytes).map { String(decoding: $0, as: UTF8.self) } } while !atEnd
        return all
    }
}

@Suite struct JSONLTailTests {
    // Mutation: return the bytes after the last newline as a line; `{"b"` comes back, red.
    @Test func aLineSplitAcrossTwoWritesComesBackWhole() throws {
        let f = try LogFiles()
        defer { f.remove() }
        try f.append("{\"a\":1}\n{\"b\"")
        var t = f.tail()
        #expect(try t.drain() == ["{\"a\":1}"])
        try f.append(":2}\n")
        #expect(try t.drain() == ["{\"b\":2}"])
        #expect(try t.drain() == [])
    }

    // Mutation: on a new inode start the new file without finishing the old; "3" is lost, red.
    @Test func aRotationLosesNoLineAndRepeatsNone() throws {
        let f = try LogFiles()
        defer { f.remove() }
        try f.append("1\n2\n")
        var t = f.tail()
        #expect(try t.drain() == ["1", "2"])
        try f.append("3\n")
        try FileManager.default.moveItem(at: f.current, to: f.older)
        try f.append("4\n5\n")
        #expect(try t.drain() == ["3", "4", "5"])
        try f.append("6\n")
        #expect(try t.drain() == ["6"])
    }

    // Mutation: ignore a size below the offset; nothing more is read after the truncation, red.
    @Test func aTruncationStartsAgainFromZero() throws {
        let f = try LogFiles()
        defer { f.remove() }
        try f.append("first line\nsecond line\n")
        var t = f.tail()
        #expect(try t.drain().count == 2)
        let h = try FileHandle(forWritingTo: f.current)
        try h.truncate(atOffset: 0)
        try h.close()
        try f.append("new\n")
        #expect(try t.drain() == ["new"])
    }

    // Mutation: start the first open at 0; "a" comes back, red.
    @Test func aFirstOpenReadsTheLastWindowOfBothGenerations() throws {
        let f = try LogFiles()
        defer { f.remove() }
        try f.append("a\n", to: f.older)
        let h = try FileHandle(forWritingTo: f.older) // a sparse line of zeros past the window
        try h.truncate(atOffset: UInt64(2 + JSONLTail.firstOpenWindow + (1 << 20)))
        try h.close()
        try f.append("\nb\n", to: f.older)
        try f.append("c\n")
        var t = f.tail()
        #expect(try t.drain() == ["b", "c"])
    }

    // Mutation: drop O_NONBLOCK; the open blocks until the time limit, red.
    // Mutation: drop the regular-file check; reading the directory fails (EISDIR) and throws, red.
    @Test(.timeLimit(.minutes(1))) func aFIFOOrADirectoryIsNoFile() throws {
        let f = try LogFiles()
        defer { f.remove() }
        try f.append("old\n", to: f.older)
        #expect(mkfifo(f.current.path, 0o600) == 0)
        var t = f.tail()
        #expect(try t.drain() == ["old"])
        #expect(try t.read(maxBytes: 1024) == [] && t.atEnd)
        var dir = JSONLTail(current: f.root, older: f.older)
        #expect(try dir.drain() == ["old"])
    }

    // Mutation: loop until a line or the end (`while true`); the first call reads all 20 GiB, red.
    @Test func eachCallReadsAtMostMaxBytesOfASparseFileAfterARotation() throws {
        let f = try LogFiles()
        defer { f.remove() }
        try f.append("1\n")
        var t = f.tail()
        #expect(try t.drain() == ["1"])
        try FileManager.default.moveItem(at: f.current, to: f.older)
        FileManager.default.createFile(atPath: f.current.path, contents: nil)
        let h = try FileHandle(forWritingTo: f.current)
        try h.truncate(atOffset: 20 << 30)
        try h.close()
        let maxBytes = 1 << 20
        let clock = ContinuousClock()
        for k in 1...8 {
            let started = clock.now
            #expect(try t.read(maxBytes: maxBytes) == [] && !t.atEnd)
            #expect(clock.now - started < .seconds(1))
            #expect(t.offset == Int64(k * maxBytes))
        }
    }

    // Mutation: read the whole remaining file in one call (`want = size - offset`); the
    // allocation in use after a call is then the whole file, red.
    @Test func a200MiBFileIsReadOneChunkAtATime() throws {
        let f = try LogFiles()
        defer { f.remove() }
        let line = "{\"v\":1,\"time_ns\":1,\"pad\":\"" + String(repeating: "x", count: 995) + "\"}\n"
        #expect(line.utf8.count == 1024)
        let block = Data(String(repeating: line, count: 1024).utf8)
        FileManager.default.createFile(atPath: f.current.path, contents: nil)
        var t = f.tail() // opened while empty, so the whole file is read, not the first open's window
        #expect(try t.read(maxBytes: 1) == [] && t.atEnd)
        let h = try FileHandle(forWritingTo: f.current)
        for _ in 0..<200 { try h.write(contentsOf: block) }
        try h.close()

        let maxBytes = 4 << 20
        let base = inUse()
        var peak = 0, count = 0, calls = 0
        while true {
            let lines = try t.read(maxBytes: maxBytes)
            peak = max(peak, inUse() - base)
            if t.atEnd { break }
            #expect(lines.reduce(0) { $0 + $1.count } <= maxBytes)
            count += lines.count
            calls += 1
        }
        #expect(count == 200 * 1024)
        #expect(calls >= 50)
        // A chunk, its lines and their copies: well under 64 MiB, a quarter of the file.
        #expect(peak < 64 << 20, "peak \(peak >> 20) MiB")
    }

    private func inUse() -> Int {
        var s = malloc_statistics_t()
        malloc_zone_statistics(nil, &s)
        return s.size_in_use
    }
}

@Suite struct LineTests {
    // Mutation: drop the schema check; the `"v": 99` line decodes, red.
    // Mutation: leave `refused` out of the names that end a wait; it reads as another event, red.
    @Test func anUnparseableLineAndAnotherSchemaAreSkipped() throws {
        let good = #"{"v":1,"time_ns":5,"level":"green","headroom_ok":true,"headroom_mib":2000,"reserve_mib":256,"room_mib":1500,"live_holds":1,"jobs":[{"hold":"h1","label":"a","footprint_mib":12,"extra":1}],"new_key":true}"#
        let f = try LogFiles()
        defer { f.remove() }
        try f.append([good, "{\"v\":1,\"time_ns\":", good.replacingOccurrences(of: "\"v\":1", with: "\"v\":99"), good]
            .joined(separator: "\n") + "\n")
        var t = f.tail()
        let parsed = try t.drain().compactMap { SampleLine(line: Data($0.utf8)) }
        #expect(parsed.count == 2)
        #expect(parsed.first?.jobs == [SampleLine.Job(hold: "h1", label: "a", footprintMiB: 12)])
        let event = #"{"v":99,"e":"cancelled","run":"r","attempt":1,"n":3,"time_ns":1,"label":"a"}"#
        #expect(EventLine(line: Data(event.utf8)) == nil)
        for e in ["cancelled", "interrupted", "refused", "timeout", "not_started", "stopped"] {
            let kind = EventLine(line: Data(event.replacingOccurrences(of: "99", with: "1").replacingOccurrences(of: "cancelled", with: e).utf8))?.kind
            #expect(kind == (e == "stopped" ? .other(e) : .waitEnded(e)), "\(e)")
        }
    }

    // Mutation: decode `vm` with `try`, without `try?`; the line with a bad `vm` is skipped, red.
    // Mutation: leave `vm` out (nil); the VM's process is lost, red.
    @Test func aMemoryLineKeepsItsVMAndABadVMCostsItNothing() throws {
        let line = { (vm: String) in
            MemoryLine(line: Data(#"{"v":1,"e":"memory","time_ns":7,"top":[{"name":"a","footprint_mib":9}]\#(vm)}"#.utf8))
        }
        let vm = MemoryLine.Process(name: "com.docker.krun", footprintMiB: 4885)
        #expect(try #require(line(#","vm":{"name":"com.docker.krun","footprint_mib":4885,"resident_mib":361}"#)).vm == vm)
        let bad = try #require(line(#","vm":{"name":7}"#))
        #expect(bad.vm == nil && bad.top == [MemoryLine.Process(name: "a", footprintMiB: 9)])
        #expect(try #require(line("")).vm == nil)
    }

    // Mutation: decode `record` with `try`, without `try?`; the line with a bad record is skipped, red.
    // Mutation: leave `record` out (nil); the exit status and the peak are lost, red.
    @Test func anEndedLineKeepsItsRecordAndABadRecordCostsItNothing() throws {
        let line = { (record: String) in
            EventLine(line: Data(#"{"v":1,"e":"ended","run":"r","attempt":1,"n":3,"time_ns":9,"label":"a","signal":"TERM","record":\#(record)}"#.utf8))
        }
        let good = try #require(line(#"{"time_ns":5,"label":"a","waited_s":1.5,"ran_s":2,"mem_peak_kib":2048,"exit":143,"fail_open":""}"#))
        guard case .ended(let d) = good.kind else { Issue.record("not ended"); return }
        #expect(d.signal == "TERM" && d.record?.exit == 143 && d.record?.memPeakKiB == 2048)
        let bad = try #require(line(#"{"time_ns":"x"}"#))
        guard case .ended(let b) = bad.kind else { Issue.record("not ended"); return }
        #expect(b.record == nil && b.signal == "TERM")
    }

    // Mutation: spell Enqueue's `real_memory` key `realMemory`; every enqueue line is skipped, red.
    @Test(arguments: Fixture.telemetryNames)
    func everyFixtureLineDecodes(_ name: String) throws {
        let dir = Fixture.directory.appending(path: name)
        var samples = JSONLTail(stateDir: dir, log: .samples)
        let s = try samples.drain()
        #expect(!s.isEmpty)
        #expect(s.filter { SampleLine(line: Data($0.utf8)) == nil } == [])
        var events = JSONLTail(stateDir: dir, log: .events)
        let e = try events.drain()
        #expect(!e.isEmpty)
        #expect(e.filter { EventLine(line: Data($0.utf8)) == nil && MemoryLine(line: Data($0.utf8)) == nil } == [])
    }

    // Mutation: make `stops` non-optional (`c.decode`); every line but a stop's is skipped, red.
    @Test(arguments: Fixture.telemetryNames)
    func everyFixtureRunLogLineDecodes(_ name: String) throws {
        var runs = JSONLTail(stateDir: Fixture.directory.appending(path: name), log: .runs)
        let lines = try runs.drain()
        #expect(!lines.isEmpty)
        #expect(lines.filter { RunLogLine(line: Data($0.utf8)) == nil } == [])
    }
}

@Suite struct RecordStateTests {
    // Mutation: `sampleAge < 30`; the sample 30 s ago is not on, red.
    // Mutation: a hold live `> 60` s; 60 s with no sample is unknown, red.
    @Test func theBoundaries() {
        let now = Date(timeIntervalSince1970: 1000)
        let ago = { (s: Double) in now.addingTimeInterval(-s) }
        #expect(RecordState(now: now, lastSample: ago(30), holdLiveSince: nil) == .on)
        #expect(RecordState(now: now, lastSample: ago(31), holdLiveSince: nil) == .unknown)
        #expect(RecordState(now: now, lastSample: nil, holdLiveSince: ago(59)) == .unknown)
        #expect(RecordState(now: now, lastSample: nil, holdLiveSince: ago(60)) == .looksOff)
    }
}

@Suite struct RunsTests {
    private func line(_ run: String, _ attempt: Int64, _ n: Int64, _ kind: EventLine.Kind) -> EventLine {
        EventLine(run: run, attempt: attempt, n: n, timeNS: n * 1_000_000_000, label: "demo:a", kind: kind)
    }

    private func enqueue(_ ticket: String) -> EventLine.Kind {
        .enqueue(try! JSONDecoder().decode(EventLine.Enqueue.self, from: Data(
            #"{"ticket":"\#(ticket)","typical_s":30,"real_memory":false,"need_mib":512}"#.utf8)))
    }

    // Mutation: key the attempts by `run` alone; attempt 2's lines overwrite attempt 1's, red.
    @Test func theLastWaitingLineOfEachAttemptIsFoundByItsTicket() {
        var runs = Runs()
        runs.apply(line("r", 1, 1, enqueue("t1")))
        runs.apply(line("r", 1, 2, .waiting(.init(reason: "behind_ticket", ahead: "x"))))
        runs.apply(line("r", 1, 3, .waiting(.init(reason: "room_short", roomMiB: 100))))
        runs.apply(line("r", 1, 4, .waiting(.init(reason: "behind_head", noPass: "too_long"))))
        runs.apply(line("r", 2, 1, enqueue("t2")))
        runs.apply(line("r", 2, 2, .waiting(.init(reason: "restart_calm"))))

        let first = runs.waiting(ticketName: "t1")
        #expect(first?.waiting == .init(reason: "behind_head", noPass: "too_long"))
        #expect(first?.waitingNS == 4_000_000_000 && first?.typicalS == 30 && first?.needMiB == 512)
        #expect(runs.waiting(ticketName: "t2")?.waiting?.reason == "restart_calm")
        #expect(runs.waiting(ticketName: "t3") == nil)
    }

    // Mutation: ignore `cancelled`; the attempt keeps no end, red.
    @Test func aCancelledLineEndsTheWait() {
        var runs = Runs()
        runs.apply(line("r", 1, 1, enqueue("t1")))
        runs.apply(line("r", 1, 2, .waiting(.init(reason: "room_short"))))
        runs.apply(line("r", 1, 3, .waitEnded("cancelled")))
        let a = runs.waiting(ticketName: "t1")
        #expect(a?.end == Runs.End(event: "cancelled", timeNS: 3_000_000_000))
        #expect(a?.admittedNS == nil)
    }

    // Mutation: keep the ticket index whole (drop its filter); "t1" still names a key, red.
    // Mutation: drop an attempt with no end too (`?? false`); the waiting attempt goes, red.
    @Test func pruneDropsOnlyWhatEndedBeforeTheDate() {
        var runs = Runs()
        for (run, ticket) in [("old", "t1"), ("late", "t2"), ("live", "t3")] { runs.apply(line(run, 1, 1, enqueue(ticket))) }
        runs.apply(line("old", 1, 5, .waitEnded("cancelled")))
        runs.apply(line("late", 1, 20, .waitEnded("refused")))
        runs.prune(endedBefore: Date(timeIntervalSince1970: 10))
        #expect(runs.byTicket["t1"] == nil && runs.attempts.count == 2)
        #expect(runs.waiting(ticketName: "t2")?.end?.event == "refused" && runs.waiting(ticketName: "t3")?.end == nil)
    }

    // Mutation: take a line with `ahead` as the head's; the head's stretch is cut at 20 s, red.
    // Mutation: leave out the attempt's admission; the first stretch runs on to 55 s, red.
    // Mutation: drop the `headLineNS` bound; the last head's stretch runs to the window's end, red.
    // Mutation: start each stretch at its line, not at the window (`max(h.timeNS, fromNS)` → `h.timeNS`), red.
    @Test func aHeadsReasonHoldsUntilTheNextHeadItsAdmissionOrThirtyTwoSeconds() {
        var runs = Runs()
        runs.apply(line("a", 1, 1, enqueue("t1")))
        runs.apply(line("a", 1, 10, .waiting(.init(reason: "room_short"))))
        runs.apply(line("c", 1, 20, .waiting(.init(reason: "behind_ticket", ahead: "t1"))))
        runs.apply(line("a", 1, 40, .waiting(.init(reason: "room_short"))))
        runs.apply(line("a", 1, 50, .admitted))
        runs.apply(line("b", 1, 55, .waiting(.init(reason: "behind_head", noPass: "too_long"))))
        let s = { (from: Int64, to: Int64, reason: String) in Runs.HeadReason(fromNS: from * 1_000_000_000, toNS: to * 1_000_000_000, reason: reason) }
        #expect(runs.headReasons(fromNS: 0, toNS: 200_000_000_000) == [s(10, 40, "room_short"), s(40, 50, "room_short"), s(55, 87, "behind_head")])
        #expect(runs.headReasons(fromNS: 45_000_000_000, toNS: 60_000_000_000) == [s(45, 50, "room_short"), s(55, 60, "behind_head")])
    }

    // Mutation: record the ticket from the waiting line instead of `enqueue`; nothing is found, red.
    @Test(arguments: Fixture.statusNames.filter { $0 != "status-0.7.0.json" })
    func everyFixtureTicketHasItsWaitingLine(_ status: String) throws {
        let doc = try StatusDocument.decode(Fixture.data(status))
        let name = status.replacingOccurrences(of: "status-", with: "telemetry-").replacingOccurrences(of: ".json", with: "")
        var tail = JSONLTail(stateDir: Fixture.directory.appending(path: name), log: .events)
        var runs = Runs()
        for l in try tail.drain() { if let e = EventLine(line: Data(l.utf8)) { runs.apply(e) } }
        for t in doc.tickets {
            let ticket = try #require(t.name)
            let a = try #require(runs.waiting(ticketName: ticket), "\(status) \(t.label)")
            #expect(a.label == t.label && a.waiting != nil)
        }
    }
}

@Suite struct RunLogTests {
    // Mutation: decode `ran_s` unclamped (`c.decode(Double.self, …)`); 1e300 stays, red.
    @Test func secondsAreClampedAndANaNIsNoLine() throws {
        let line = { (waited: String) in
            RunLogLine(line: Data(#"{"time_ns":1,"label":"demo:a","waited_s":\#(waited),"ran_s":1e300,"exit":0,"fail_open":""}"#.utf8))
        }
        let r = try #require(line("1e10"))
        #expect(r.waitedS == 1e10 && r.ranS == 0x1p40)
        #expect(Formatting.duration(r.waitedS) == "2777777 h 47 min")
        #expect(line("NaN") == nil) // JSON has no NaN
    }
}
