import Foundation
import Testing
@testable import CoreslotKit

/// The recorded states of `Fixtures/`, written by scripts/make-fixtures.sh.
enum Fixture {
    static let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    static var statusNames: [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return all.filter { $0.hasPrefix("status-") && $0.hasSuffix(".json") }.sorted()
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }

    static func object(_ name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

@Suite struct StatusTests {
    @Test func theFixturesAreThere() {
        #expect(Fixture.statusNames.count >= 7, "\(Fixture.statusNames)")
    }

    // Mutation: make Hold.container non-optional; every fixture with a hold goes red.
    @Test(arguments: Fixture.statusNames)
    func everyFixtureDecodes(_ name: String) throws {
        let doc = try StatusDocument.decode(Fixture.data(name))
        #expect(doc.schema == 1)
    }

    // Mutation: spell the key of Hold.stoppable `stopable` (it then decodes nil), red.
    @Test(arguments: Fixture.statusNames)
    func theNewKeysReadAsTheFixtureHasThem(_ name: String) throws {
        let doc = try StatusDocument.decode(Fixture.data(name))
        let raw = try Fixture.object(name)
        let holds = raw["holds"] as! [[String: Any]]
        let tickets = raw["tickets"] as! [[String: Any]]
        let mem = raw["mem"] as? [String: Any]
        #expect(doc.holds.map(\.stoppable) == holds.map { $0["stoppable"] as? Bool })
        #expect(doc.holds.map(\.leftS) == holds.map { ($0["left_s"] as? NSNumber)?.int64Value })
        #expect(doc.holds.map(\.typicalS) == holds.map { ($0["typical_s"] as? NSNumber)?.int64Value })
        #expect(doc.tickets.map(\.expectedWaitS)
            == tickets.map { ($0["expected_wait_s"] as? NSNumber)?.int64Value })
        #expect(doc.tickets.map(\.name) == tickets.map { $0["name"] as? String })
        #expect(doc.mem?.roomMiB == (mem?["room_mib"] as? NSNumber)?.int64Value)
        #expect(doc.mem?.machineMiB == (mem?["machine_mib"] as? NSNumber)?.int64Value)
    }

    // The queue fixture is the one that gives each new key a value, so the comparison above bites.
    @Test func theQueueFixtureCarriesEveryNewKey() throws {
        let doc = try StatusDocument.decode(Fixture.data("status-queue.json"))
        #expect(doc.holds.count == 2 && doc.tickets.count == 2)
        #expect(Set(doc.holds.compactMap(\.stoppable)) == [true, false])
        #expect(doc.holds.contains { ($0.leftS ?? 0) > 0 })
        #expect(doc.tickets[0].expectedWaitS != nil)
        #expect(doc.tickets[1].expectedWaitS == nil)
        #expect(doc.tickets.allSatisfy { $0.name != nil })
        #expect(doc.mem?.roomMiB != nil && doc.mem?.headroomMiB != nil && doc.mem?.reserveMiB != nil)
    }

    // Mutation: make Hold.leftS non-optional; this goes red.
    @Test func aDocumentOfCoreslot070Decodes() throws {
        let doc = try StatusDocument.decode(Fixture.data("status-0.7.0.json"))
        #expect(doc.holds.count == 2 && doc.tickets.count == 2)
        for h in doc.holds {
            #expect(h.typicalS == nil && h.leftS == nil && h.stoppable == nil)
        }
        for t in doc.tickets {
            #expect(t.name == nil && t.expectedWaitS == nil)
        }
        let mem = try #require(doc.mem)
        #expect(mem.machineMiB == nil && mem.reserveMiB == nil && mem.headroomMiB == nil)
        #expect(mem.roomMiB == nil && mem.freeMiB == 205)
    }

    // Mutation: spell Degraded's `first_ns` as `firstNS`; red, since only this case has a record.
    @Test func anUnknownKeyAtEveryLevelDecodes() throws {
        let extra: [String: Any] = ["later": ["a": [1, "b", NSNull()]]]
        var doc = try Fixture.object("status-queue.json")
        doc.merge(extra) { a, _ in a }
        doc["degraded"] = ["reason": "r", "first_ns": 1, "count": 2, "malformed": false].merging(extra) { a, _ in a }
        doc["section"] = [
            "held": true,
            "holder": ["pid": 4, "entered_ns": 5, "held_for_s": 0.5, "alive": true].merging(extra) { a, _ in a },
        ].merging(extra) { a, _ in a }
        for key in ["mem", "watch"] {
            doc[key] = (doc[key] as! [String: Any]).merging(extra) { a, _ in a }
        }
        for key in ["holds", "tickets"] {
            doc[key] = (doc[key] as! [[String: Any]]).map { $0.merging(extra) { a, _ in a } }
        }
        doc["ignored"] = (doc["ignored"] as! [String: Any]).merging(["later": 7]) { a, _ in a }

        let decoded = try StatusDocument.decode(Fixture.encode(doc))
        #expect(decoded.degraded == .init(reason: "r", firstNS: 1, count: 2, malformed: false))
        #expect(decoded.section.holder?.pid == 4 && decoded.section.holder?.alive == true)
        #expect(decoded.holds.count == 2 && decoded.tickets.count == 2)
        #expect(decoded.ignored["later"] == 7)
    }

    // Mutation: make StatusDocument.mem non-optional; red (the suite no longer compiles).
    @Test func aNullMemIsNil() throws {
        var doc = try Fixture.object("status-queue.json")
        doc["mem"] = NSNull()
        #expect(try StatusDocument.decode(Fixture.encode(doc)).mem == nil)
    }

    // Mutation: type Hold.pid as Int32; red.
    @Test func aPidBeyondInt32Decodes() throws {
        var doc = try Fixture.object("status-queue.json")
        doc["holds"] = (doc["holds"] as! [[String: Any]]).map { $0.merging(["pid": 9_999_999_999]) { _, b in b } }
        doc["tickets"] = (doc["tickets"] as! [[String: Any]]).map { $0.merging(["pid": 9_999_999_999]) { _, b in b } }
        let decoded = try StatusDocument.decode(Fixture.encode(doc))
        #expect(decoded.holds.map { Int64($0.pid) } == [9_999_999_999, 9_999_999_999])
        #expect(decoded.tickets.map { Int64($0.pid) } == [9_999_999_999, 9_999_999_999])
    }
}
