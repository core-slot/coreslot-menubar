import Foundation
import Testing
@testable import CoreslotKit

@Suite struct LogTests {
    /// Each call's lines, as `text`, or `!text` for a failure.
    private func said(_ lines: [LogLine]) -> [String] { lines.map { ($0.failure ? "!" : "") + $0.text } }

    // Mutation: drop `now == kind ? [] :` (a line every poll); red. Mutation: `failure: false`; red.
    @Test func theKindIsLoggedWhenItChangesAndOnceWhenItRecovers() throws {
        let doc = try StatusDocument.decode(Fixture.data("status-queue.json"))
        var t = LogTransitions()
        let readings: [StatusReading] = [.document(doc, []), .document(doc, []), .problem(.failed(exitCode: 64)),
                                         .problem(.failed(exitCode: 64)), .problem(.stateUnreadable), .notices([.schema(2)]), .document(doc, [])]
        #expect(readings.map { said(t.reading($0)) } == [
            ["status: document"], [], ["!status: document -> problem: exit 64"], [],
            ["!status: problem: exit 64 -> problem: state unreadable, exit 3"],
            ["status: problem: state unreadable, exit 3 -> notices only (schema 2)", "notice: schema 2"],
            ["status: notices only (schema 2) -> document", "notice cleared: schema 2"],
        ])
    }

    // Mutation: return the notice's text without `SafeText.display`; red.
    // Mutation: diff notices on a problem too (`case .problem: []`); red.
    @Test func noticesAreLoggedAsTheyAppearAndClearAndAProblemLeavesThem() throws {
        let doc = try StatusDocument.decode(Fixture.data("status-queue.json"))
        var t = LogTransitions()
        _ = t.reading(.document(doc, []))
        #expect(said(t.reading(.document(doc, [.degraded("a\u{202E}b"), .tooOld]))) == [#"notice: degraded: a\u{202E}b"#, "notice: coreslot older than 0.8.0"])
        #expect(said(t.reading(.problem(.timedOut))) == ["!status: document -> problem: timed out"])
        #expect(said(t.reading(.document(doc, [.tooOld]))) == ["status: problem: timed out -> document", #"notice cleared: degraded: a\u{202E}b"#])
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
        #expect([["samples.jsonl: errno 13"], ["samples.jsonl: errno 13"], [], ["samples.jsonl: errno 13"]].map { said(t.read(errors: $0)) } == [
            ["!read error: samples.jsonl: errno 13"], [], ["read again: samples.jsonl: errno 13"], ["!read error: samples.jsonl: errno 13"],
        ])
    }
}
