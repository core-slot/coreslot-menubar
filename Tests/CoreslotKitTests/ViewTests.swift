import Foundation
import Testing
@testable import CoreslotKit

private func document(_ name: String, _ change: (inout [String: Any]) -> Void = { _ in }) throws -> StatusDocument {
    var raw = try Fixture.object(name)
    change(&raw)
    return try StatusDocument.decode(Fixture.encode(raw))
}

private func mem(_ raw: inout [String: Any], _ key: String, _ value: Any) {
    var m = raw["mem"] as! [String: Any]
    m[key] = value
    raw["mem"] = m
}

@Suite struct IconStateTests {
    @Test(arguments: [
        ("status-idle.json", IconState.idle), ("status-stopped.json", .idle),
        ("status-queue.json", .waiting(fill: 0)), ("status-no-typical.json", .waiting(fill: 0)),
        ("status-cancelled.json", .running(fill: 0)), ("status-dead.json", .running(fill: 0)),
        ("status-0.7.0.json", .waiting(fill: 0)),
    ])
    func perFixture(_ name: String, _ want: IconState) throws {
        #expect(IconState(.document(try document(name), [])) == want)
    }

    // Mutation: make `.tooOld` unavailable like `.schema`; the 0.7.0 reading goes dark, red.
    @Test func perNoticeAndProblem() throws {
        let old = try document("status-0.7.0.json")
        #expect(IconState(.document(old, [.tooOld(Version(0, 7, 0))])) == .waiting(fill: 0))
        let queue = try document("status-queue.json")
        for n: Notice in [.development, .degraded("x"), .formatNotUnderstood, .configError("x")] {
            #expect(IconState(.document(queue, [n])) == .waiting(fill: 0), "\(n)")
        }
        #expect(IconState(.document(StatusDocument.schemaOnly(2), [.schema(2)])) == .unavailable)
        for p: Problem in [.notFound, .stateUnreadable(stderr: ""), .failed(exitCode: 70), .malformed, .timedOut] {
            #expect(IconState(.problem(p)) == .unavailable, "\(p)")
        }
    }

    // Mutation: round the fill down; 12000 of 16384 is 2.9 quarters and shows 2, red.
    @Test func pressureAndTheFill() throws {
        for level in ["yellow", "red", "floor"] {
            let doc = try document("status-queue.json") { raw in
                var w = raw["watch"] as! [String: Any]
                w["level"] = level
                raw["watch"] = w
            }
            #expect(IconState(.document(doc, [])) == .pressure, "\(level)")
        }
        let full = try document("status-cancelled.json") { mem(&$0, "reserved_mib", 12000) }
        #expect(IconState(.document(full, [])) == .running(fill: 3))
        let over = try document("status-cancelled.json") { mem(&$0, "reserved_mib", 40000) }
        #expect(IconState(.document(over, [])) == .running(fill: 4))
    }
}

@Suite struct MemoryBarTests {
    // Mutation: leave the reserve out of the segments; no bar adds up to the machine, red.
    @Test(arguments: Fixture.statusNames.filter { $0 != "status-0.7.0.json" })
    func aBarAddsUpToTheMachine(_ name: String) throws {
        let doc = try document(name) { raw in
            var holds = raw["holds"] as! [[String: Any]]
            for i in holds.indices { holds[i]["footprint_mib"] = 700 * (i + 1) }
            raw["holds"] = holds
        }
        let bar = try #require(MemoryBar(doc))
        let m = try #require(doc.mem)
        #expect(bar.segments.reduce(0) { $0 + $1.mib } == m.machineMiB)
        #expect(bar.segments.last == MemoryBar.Segment(kind: .reserve, mib: m.reserveMiB!))
        #expect(bar.segments.first { $0.kind == .room }?.mib == m.roomMiB)
        #expect(bar.shortfallMiB == nil)
        let held = doc.holds.reduce(0) { $0 + $1.footprintMiB }
        #expect(bar.segments.first { $0.kind == .outside }?.mib == m.machineMiB! - m.headroomMiB! - held)
    }

    // Mutation: leave the footprints uncut; the outside segment goes negative, red.
    @Test func footprintsAboveMemoryInUseAreCutToIt() throws {
        let doc = try document("status-queue.json") { raw in
            var holds = raw["holds"] as! [[String: Any]]
            for i in holds.indices { holds[i]["footprint_mib"] = 10000 }
            raw["holds"] = holds
        }
        let bar = try #require(MemoryBar(doc))
        let m = try #require(doc.mem)
        #expect(bar.segments.reduce(0) { $0 + $1.mib } == m.machineMiB)
        #expect(bar.segments.first { $0.kind == .outside }?.mib == 0)
        #expect(bar.segments.map(\.mib).prefix(2) == [10000, m.machineMiB! - m.headroomMiB! - 10000])
    }

    @Test func noBarWithoutMem() throws {
        #expect(MemoryBar(try document("status-0.7.0.json")) == nil)
        #expect(MemoryBar(try document("status-queue.json") { $0["mem"] = NSNull() }) == nil)
    }

    // Mutation: decode `mem.room_mib` unclamped; `headroom − reserve − Int64.min` traps, red (crash).
    @Test func aRoomOfInt64MinCannotTrap() throws {
        let bar = try #require(MemoryBar(try document("status-queue.json") { mem(&$0, "room_mib", Int64.min) }))
        #expect(bar.shortfallMiB == 1 << 40)
    }

    // Mutation: clip the shortfall to 0 (`room < 0 ? 0 : nil`); red.
    @Test func aNegativeRoomKeepsTheWidthAndSaysTheShortfall() throws {
        let doc = try document("status-queue.json") { mem(&$0, "room_mib", -3000) }
        let bar = try #require(MemoryBar(doc))
        let m = try #require(doc.mem)
        #expect(bar.segments.reduce(0) { $0 + $1.mib } == m.machineMiB)
        #expect(bar.shortfallMiB == 3000)
        #expect(bar.segments.first { $0.kind == .room }?.mib == 0)
        #expect(bar.segments.first { $0.kind == .setAside }?.mib == m.headroomMiB! - m.reserveMiB!)
    }
}

@Suite struct WordsTests {
    private func watch(_ level: String, learning: Int64 = 0) -> StatusDocument.Watch {
        StatusDocument.Watch(level: level, excessPoints: 0, protecting: true, reason: "", nextVictim: "", learning: learning)
    }

    // Mutation: say "Learning" whatever the level once `learning` > 0; the yellow case, red.
    @Test(arguments: [
        ("green", 0, "Memory normal"), ("green", 2, "Learning"), ("yellow", 2, "Memory tight"),
        ("red", 0, "Stopping commands"), ("floor", 0, "Memory critically low"), ("", 0, "No recent reading"),
        ("unknown", 0, "No recent reading"),
    ] as [(String, Int64, String)])
    func theLevel(_ level: String, _ learning: Int64, _ want: String) {
        #expect(Words.level(watch(level, learning: learning)) == want)
    }

    // Mutation: put `degraded.reason` in the sentence without SafeText; the U+202E arrives, red.
    // Mutation: say the level for a schema-only document too; "No recent reading · …", red.
    @Test func theNotices() throws {
        #expect(Words.header(try document("status-queue.json"), notices: [.tooOld(Version(0, 7, 0))])
            == "Learning · Update coreslot to 0.8.0 or later")
        #expect(Words.notice(.degraded("lock\u{202E}txt")) == "coreslot is degraded: lock\\u{202E}txt")
        #expect(Words.notice(.configError("bad\nline")) == "coreslot's configuration has a problem: bad\\u{000A}line")
        #expect(Words.notice(.formatNotUnderstood) == "This coreslot writes a format this app does not know")
        #expect(Words.notice(.schema(2)) == "This coreslot's status document is newer than this app")
        #expect(Words.notice(.development) == nil)
        #expect(Words.header(.schemaOnly(2), notices: [.schema(2), .development])
            == "This coreslot's status document is newer than this app")
    }

    // Mutation: drop "on the machine" for a container request; red.
    @Test(arguments: [
        (EventLine.Waiting(reason: "room_short", roomMiB: 400), false, "Needs 1.5 GiB, 400 MiB free"),
        (.init(reason: "room_short", roomMiB: 400), true, "Needs 1.5 GiB, 400 MiB free on the machine"),
        (.init(reason: "room_short"), false, "Needs 1.5 GiB, more than is free"),
        (.init(reason: "behind_head"), false, "Fits, but behind the first in line"),
        (.init(reason: "behind_head", noPass: "too_long"), false, "Fits, but runs longer than the first in line waits"),
        (.init(reason: "behind_head", noPass: "no_typical"), false, "Fits, but behind the first in line"),
        (.init(reason: "behind_ticket", ahead: "t"), false, "Waits its turn"),
        (.init(reason: "section_busy"), false, "Waiting for the queue"),
        (.init(reason: "watch_level"), false, "Memory is tight"),
        (.init(reason: "watch_spacing"), false, "Starting one at a time after memory pressure"),
        (.init(reason: "restart_stale"), false, "Restarting after a memory stop"),
        (.init(reason: "restart_margin"), false, "Restarting after a memory stop"),
    ] as [(EventLine.Waiting, Bool, String)])
    func theReasons(_ w: EventLine.Waiting, _ realMemory: Bool, _ want: String) {
        #expect(Words.reason(w, needMiB: 1536, realMemory: realMemory, ageS: 5) == want)
    }

    // Mutation: say the age from 0 s on; the 5 s case gains "· 5 s ago", red.
    @Test func anUnknownReasonAndTheAge() {
        #expect(Words.reason(.init(reason: "new_code"), needMiB: 1, realMemory: false, ageS: 0) == nil)
        #expect(Words.reason(.init(reason: "behind_ticket"), needMiB: 1, realMemory: false, ageS: 20)
            == "Waits its turn · 20 s ago")
        #expect(Words.reason(.init(reason: "behind_ticket"), needMiB: 1, realMemory: false, ageS: 5) == "Waits its turn")
    }

    // Mutation: test `processChecked` before `container`; a container hold that was not checked, red.
    @Test func theQuietLine() {
        #expect(Words.quietLine(container: true, processChecked: false) == "Container work: stop the container")
        #expect(Words.quietLine(container: false, processChecked: false) == "This process could not be checked")
        #expect(Words.quietLine(container: false, processChecked: true) == "Stop it where it was started")
    }
}

@Suite struct FormattingTests {
    // Mutation: floor the minutes; 2 h 4 min 59 s reads "2 h 4 min", red.
    @Test(arguments: [
        (Int64(0), "0 s"), (59, "59 s"), (61, "1 min"), (7500, "2 h 5 min"), (7499, "2 h 5 min"), (7200, "2 h"),
    ] as [(Int64, String)])
    func aDuration(_ s: Int64, _ want: String) {
        #expect(Formatting.duration(s) == want)
    }

    // Mutation: print whole GiB with ".0" ("1.0 GiB"), which coreslot does not; red.
    @Test(arguments: [(Int64(1023), "1023 MiB"), (1024, "1 GiB"), (1536, "1.5 GiB"), (1100, "1.1 GiB")] as [(Int64, String)])
    func aSize(_ mib: Int64, _ want: String) {
        #expect(Formatting.size(mib) == want)
    }

    // Mutation: read a 0 as "≈ 0 s" for the first ticket; red.
    @Test func theForecasts() {
        #expect(Formatting.firstTicketWait(61) == "starts in ≈ 1 min")
        #expect(Formatting.firstTicketWait(0) == "next")
        #expect(Formatting.firstTicketWait(nil) == "no estimate")
        #expect(Formatting.timeLeft(59) == "≈ 59 s")
        #expect(Formatting.timeLeft(0) == "past its usual time")
        #expect(Formatting.timeLeft(nil) == "no estimate")
    }
}

@Suite struct SafeTextTests {
    // Mutation: let U+2028 through (drop `.lineSeparator`); red.
    @Test func everyHiddenCharacterIsShownAndDistinctStringsStayDistinct() {
        let inputs = [
            "demo:a\u{202E}b", "demo:a\u{200B}b", "demo:a\u{E0041}b", "demo:a\u{2028}b", "demo:a\nb",
            "demo:a\\u{202E}b", "demo:ab",
        ]
        let shown = inputs.map(SafeText.display)
        #expect(Set(shown).count == inputs.count)
        #expect(shown[0] == "demo:a\\u{202E}b" && shown[2] == "demo:a\\u{E0041}b" && shown[4] == "demo:a\\u{000A}b")
        #expect(shown[3] == "demo:a\\u{2028}b")
        #expect(shown[5] == "demo:a\\\\u{202E}b")
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        for s in shown {
            #expect(s.unicodeScalars.allSatisfy { !hidden.contains($0.properties.generalCategory) }, "\(Array(s.unicodeScalars))")
        }
    }
}
