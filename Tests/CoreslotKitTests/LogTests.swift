import Foundation
import Testing
@testable import CoreslotKit

@Suite struct LogTests {
    /// Each call's lines, as `text`, or `!text` for a failure.
    private func said(_ lines: [LogLine]) -> [String] { lines.map { ($0.failure ? "!" : "") + $0.text } }

    // Mutation: drop `now == kind ? [] :` (a line every poll); red. Mutation: `let failure = false`; red.
    // Mutation: word a problem as `"problem: \(p)"`, not `Words.problem` (-errno as an exit); red.
    // Mutation: `.notices` worded `"notices only (schema 2)"`, the notices said twice; red.
    @Test func theKindIsLoggedWhenItChangesAndOnceWhenItRecovers() throws {
        let doc = try StatusDocument.decode(Fixture.data("status-queue.json"))
        var t = LogTransitions()
        let (exit64, errno24) = ("problem: coreslot status failed with exit status 64", "problem: coreslot status could not be run (system error 24)")
        let readings: [StatusReading] = [.document(doc, []), .document(doc, []), .problem(.failed(exitCode: 64)), .problem(.failed(exitCode: 64)),
                                         .problem(.failed(exitCode: -24)), .problem(.stateUnreadable), .notices([.schema(2)]), .document(doc, [])]
        #expect(readings.map { said(t.reading($0)) } == [
            ["status: document"], [], ["!status: document -> \(exit64)"], [], ["!status: \(exit64) -> \(errno24)"],
            ["!status: \(errno24) -> problem: coreslot cannot read its state"],
            ["status: problem: coreslot cannot read its state -> notices only", "notice: schema 2"],
            ["status: notices only -> document", "notice cleared: schema 2"],
        ])
    }

    // N5: notices-only readings in a row are one kind, whatever their notices. Mutation: a kind line
    // on every notices-only reading (`now == kind && now != .notices ? [] :`); red.
    @Test func noticesOnlyReadingsInARowSayOnlyTheirNotices() {
        var t = LogTransitions()
        #expect([[.schema(2)], [.schema(2), .tooOld], [.tooOld], [.tooOld]].map { said(t.reading(.notices($0))) } == [
            ["status: notices only", "notice: schema 2"], ["notice: coreslot older than 0.8.0"], ["notice cleared: schema 2"], [],
        ])
    }

    // Mutation: return the notice's text without `SafeText.display`; red.
    // Mutation: diff notices on a problem too (`case .problem: []`); red.
    @Test func noticesAreLoggedAsTheyAppearAndClearAndAProblemLeavesThem() throws {
        let doc = try StatusDocument.decode(Fixture.data("status-queue.json"))
        var t = LogTransitions()
        _ = t.reading(.document(doc, []))
        #expect(said(t.reading(.document(doc, [.degraded("a\u{202E}b"), .tooOld]))) == [#"notice: degraded: a\u{202E}b"#, "notice: coreslot older than 0.8.0"])
        let late = "problem: coreslot status did not answer in time"
        #expect(said(t.reading(.problem(.timedOut))) == ["!status: document -> \(late)"])
        #expect(said(t.reading(.document(doc, [.tooOld]))) == ["status: \(late) -> document", #"notice cleared: degraded: a\u{202E}b"#])
    }

    // Mutation: drop `guard b != binary` (a line every look); red. Mutation: "found" for a change; red.
    @Test func theBinaryIsLoggedWhenFoundChangedOrLost() {
        let a = CoreslotBinary(url: URL(filePath: "/opt/a/coreslot"), version: Version(0, 8, 0))
        let b = CoreslotBinary(url: URL(filePath: "/opt/b/coreslot"), version: .development)
        var t = LogTransitions()
        #expect([nil, a, a, b, nil, nil].map { t.located($0).map { said([$0]) } } == [
            nil, ["coreslot found: /opt/a/coreslot, version 0.8.0"], nil,
            ["coreslot changed: /opt/b/coreslot, version development build"], ["!coreslot lost at /opt/b/coreslot"], nil,
        ])
    }

    // Mutation: `old = []` instead of `old = new` (every poll's errors again); red.
    @Test func aReadErrorIsLoggedOnceWhileItLastsAndOnceWhenItEnds() {
        var t = LogTransitions()
        #expect([["samples: errno 13"], ["samples: errno 13"], [], ["samples: errno 13"]].map { said(t.read(errors: $0)) } == [
            ["!read error: samples: errno 13"], [], ["read again: samples: errno 13"], ["!read error: samples: errno 13"],
        ])
    }
}
