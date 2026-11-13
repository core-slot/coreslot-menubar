import Foundation
import Testing
@testable import CoreslotKit

private func document(_ name: String, _ change: ((inout [String: Any]) -> Void)? = nil) throws -> StatusDocument {
    try StatusDocument.decode(Fixture.data(name, change))
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

    // Mutation: show a reading of notices alone as idle, like a document with nothing in it; red.
    @Test func perNoticeAndProblem() throws {
        let old = try document("status-0.7.0.json")
        #expect(IconState(.document(old, [.tooOld])) == .waiting(fill: 0))
        let queue = try document("status-queue.json")
        for n: Notice in [.degraded("x"), .formatNotUnderstood(""), .configError("x")] {
            #expect(IconState(.document(queue, [n])) == .waiting(fill: 0), "\(n)")
        }
        #expect(IconState(.notices([.schema(2)])) == .unavailable && IconState(.notices([.tooOld])) == .unavailable)
        for p: Problem in [.notFound, .stateUnreadable, .failed(exitCode: 70), .malformed, .timedOut] {
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

    // Mutation: give the drawn set-aside width instead (`setAsideMiB = setAside`); 0, red.
    @Test func theSetAsideFigureIsUnclipped() throws {
        let doc = try document("status-queue.json") {
            mem(&$0, "headroom_mib", 500); mem(&$0, "reserve_mib", 1024); mem(&$0, "room_mib", -2524)
        }
        let bar = try #require(MemoryBar(doc))
        #expect(bar.setAsideMiB == 2000 && bar.shortfallMiB == 2524)
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
    // The idle fixture has no hold; the queue fixture has two.
    // Mutation: say "Learning" for green whenever `learning` > 0; the idle machine after a run, red.
    // Mutation: say "No recent reading" for an empty level whatever the holds; the idle case, red.
    // Mutation: say "Stopping commands" for every red; the red that is not protecting, red.
    // Mutation: put the reason or an unknown code in without SafeText; the U+202E arrives, red.
    @Test(arguments: [
        ("status-idle.json", "", 0, true, "", "Idle"),
        ("status-queue.json", "", 0, true, "", "No recent reading"),
        ("status-idle.json", "unknown", 0, true, "", "Memory reading failed"),
        ("status-idle.json", "green", 1, false, "no coreslot job is running", "Memory normal"),
        ("status-queue.json", "green", 1, true, "", "Learning"),
        ("status-queue.json", "green", 0, true, "", "Memory normal"),
        ("status-queue.json", "yellow", 2, true, "", "Memory tight"),
        ("status-queue.json", "red", 0, true, "", "Stopping commands"),
        ("status-queue.json", "red", 0, false, "", "Memory very tight"),
        ("status-queue.json", "red", 0, false, "cooling\u{202E}", "Memory very tight · not stopping: cooling\\u{202E}"),
        ("status-queue.json", "floor", 0, true, "", "Memory critically low"),
        ("status-queue.json", "violet\u{202E}", 0, true, "", "Memory level violet\\u{202E}"),
    ] as [(String, String, Int, Bool, String, String)])
    func theLevel(_ name: String, _ level: String, _ learning: Int, _ protecting: Bool, _ reason: String, _ want: String) throws {
        let doc = try document(name) {
            $0["watch"] = ($0["watch"] as! [String: Any])
                .merging(["level": level, "learning": learning, "protecting": protecting, "reason": reason]) { $1 }
        }
        #expect(Words.level(doc) == want)
    }

    // Mutation: put `degraded.reason` in the sentence without SafeText; the U+202E arrives, red.
    // Mutation: leave the format error out of its sentence; red.
    // Mutation: say "newer than this app" for every other schema; schema 0, red.
    @Test func theNotices() throws {
        #expect(Words.notice(.tooOld).header == "Update coreslot to 0.8.0 or later")
        #expect(Words.notice(.degraded("lock\u{202E}txt")).header == "coreslot is degraded: lock\\u{202E}txt")
        #expect(Words.notice(.configError("bad\nline")).header == "coreslot's configuration has a problem: bad\\u{000A}line")
        let format = "This coreslot does not understand the state directory's format: update or repair coreslot"
        #expect(Words.notice(.formatNotUnderstood("")).header == format)
        #expect(Words.notice(.formatNotUnderstood("FORMAT: 3\n")).header == format + " (FORMAT: 3\\u{000A})")
        #expect(Words.notice(.schema(2)).header == "This coreslot's status document is newer than this app")
        #expect(Words.notice(.schema(0)).header == "This coreslot's status document has a schema this app does not know")
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

    // Mutation: drop the `restart_` row of `Words.reasons`, the one table of names and words; a restart's reason has no name, red.
    @Test func theReasonsHaveNamesForTheLegend() {
        let codes = ["room_short", "behind_head", "behind_ticket", "section_busy", "watch_level", "watch_spacing", "restart_calm"]
        #expect(Set(codes.compactMap(Words.reasonName)).count == codes.count)
        #expect(Words.reasonName("restart_margin") == Words.reasonName("restart_calm") && Words.reasonName("new_code") == nil)
    }

    // Mutation: test `processChecked` before `container`; a container hold that was not checked, red.
    @Test func theQuietLine() {
        #expect(Words.quietLine(container: true, processChecked: false) == "Container work: stop the container")
        #expect(Words.quietLine(container: false, processChecked: false) == "This process could not be checked")
        #expect(Words.quietLine(container: false, processChecked: true) == "Stop it where it was started")
    }
}

@Suite struct ProblemWordsTests {
    // Mutation: give a failed `status` the state-unreadable words; exit 70 no longer says its
    // status, and the two states read the same, red.
    // Mutation: drop the brew command from the not-found fix, red.
    @Test func eachProblemIsOneStateWithItsFix() {
        let all: [Problem] = [.notFound, .stateUnreadable, .failed(exitCode: 70), .malformed, .timedOut]
        let states = all.map { Words.problem($0).state }
        #expect(Set(states).count == all.count)
        #expect(Words.problem(.stateUnreadable).state == "coreslot cannot read its state")
        #expect(Words.problem(.stateUnreadable).fix.contains("coreslot doctor"))
        #expect(Words.problem(.failed(exitCode: 70)).state == "coreslot status failed with exit status 70")
        #expect(Words.problem(.notFound).fix.contains("0.8.0"))
        #expect(Words.problem(.notFound).fix.contains("brew install core-slot/tap/coreslot"))
    }

    // Mutation: drop the negative case; -24 reads "failed with exit status -24", red.
    @Test func aStartFailureIsNotAnExitStatus() {
        #expect(Words.problem(.failed(exitCode: -EMFILE)) == ("coreslot status could not be run (system error 24)", "The next reading tries again."))
    }
}

@Suite struct FormattingTests {
    // Mutation: floor the minutes; 2 h 4 min 59 s reads "2 h 4 min", red.
    // Mutation: convert with `Int64(seconds.rounded())`, without `Clamp.seconds`; NaN traps, red (crash).
    @Test(arguments: [
        (0, "0 s"), (59.4, "59 s"), (61, "1 min"), (7500, "2 h 5 min"), (7499, "2 h 5 min"), (7200, "2 h"),
        (-3, "0 s"), (.nan, "0 s"), (1e10, "2777777 h 47 min"), (.infinity, "305419896 h 36 min"),
    ] as [(Double, String)])
    func aDuration(_ s: Double, _ want: String) {
        #expect(Formatting.duration(s) == want)
    }

    // Mutation: print whole GiB with ".0" ("1.0 GiB"), which coreslot does not; red.
    @Test(arguments: [(Int64(1023), "1023 MiB"), (1024, "1 GiB"), (1536, "1.5 GiB"), (1100, "1.1 GiB")] as [(Int64, String)])
    func aSize(_ mib: Int64, _ want: String) {
        #expect(Formatting.size(mib) == want)
    }

    // Mutation: read a 0 as "≈ 0 s" for the first ticket; red.
    // Mutation: say "finishes in " before every `left_s`, as the timeline did; red.
    @Test func theForecasts() {
        #expect(Formatting.firstTicketWait(61) == "starts in ≈ 1 min")
        #expect(Formatting.firstTicketWait(0) == "next")
        #expect(Formatting.firstTicketWait(nil) == "no estimate")
        #expect(Formatting.timeLeft(59) == "finishes in ≈ 59 s")
        #expect(Formatting.timeLeft(0) == "past its usual time")
        #expect(Formatting.timeLeft(nil) == "no estimate")
    }
}

@Suite struct SafeTextTests {
    // Mutation: let U+2028 through (drop `.lineSeparator`); red.
    // Mutation: drop the default-ignorable check; U+034F, U+3164 and U+E0100 pass, red.
    // Mutation: drop `.unassigned`; the noncharacter U+FDD0 passes, red.
    @Test func everyHiddenCharacterIsShownAndDistinctStringsStayDistinct() {
        let inputs = [
            "demo:a\u{202E}b", "demo:a\u{200B}b", "demo:a\u{E0041}b", "demo:a\u{2028}b", "demo:a\nb",
            "demo:a\\u{202E}b", "demo:ab", "demo:a\u{034F}b", "demo:a\u{3164}b", "demo:a\u{E0100}b",
            "demo:a\(Character(Unicode.Scalar(0xFDD0)!))b", // a noncharacter, unassigned for good; no literal takes it
        ]
        let shown = inputs.map(SafeText.display)
        #expect(Set(shown).count == inputs.count)
        #expect(shown[0] == "demo:a\\u{202E}b" && shown[2] == "demo:a\\u{E0041}b" && shown[4] == "demo:a\\u{000A}b")
        #expect(shown[3] == "demo:a\\u{2028}b")
        #expect(shown[5] == "demo:a\\\\u{202E}b")
        #expect(shown[7...] == ["demo:a\\u{034F}b", "demo:a\\u{3164}b", "demo:a\\u{E0100}b", "demo:a\\u{FDD0}b"])
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator, .unassigned]
        for s in shown {
            #expect(s.unicodeScalars.allSatisfy { !hidden.contains($0.properties.generalCategory) && !$0.properties.isDefaultIgnorableCodePoint },
                    "\(Array(s.unicodeScalars))")
        }
    }
}

@Suite struct LabelColorsTests {
    // Mutation: number a new label by the count (`colors.count`); "c" takes "b"'s colour, red.
    // Mutation: never forget (drop the filter); "a" stays, red. Mutation: forget by first sight (set
    // `seen` only for a new label); "b", seen 1 s before, goes, red.
    @Test func aLabelUnseenFor24HoursIsForgottenAndNoColourIsGivenTwice() {
        var c = LabelColors()
        let t0 = Date(timeIntervalSince1970: 0), day = LabelColors.forgetS
        c.see(["a", "b"], at: t0)
        c.see(["b"], at: t0.addingTimeInterval(day - 1))
        c.see([], at: t0.addingTimeInterval(day))
        c.see(["c"], at: t0.addingTimeInterval(day))
        #expect(c["a"] == nil && c["b"] == 1 && c["c"] == 2 && c.labels == ["b", "c"])
    }
}
