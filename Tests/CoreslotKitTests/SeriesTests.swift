import Foundation
import Testing
@testable import CoreslotKit

@Suite struct SeriesTests {
    static let machine: Int64 = 16384
    /// A multiple of every resolution, so a bucket starts here.
    static let t0: Int64 = 1_800_000_000

    private func sample(
        _ s: Int64, headroom: Int64 = 5000, reserve: Int64 = 256, room: Int64 = 3000, ok: Bool = true,
        _ jobs: [(String, Int64)] = []
    ) -> SampleLine {
        SampleLine(
            timeNS: (Self.t0 + s) * 1_000_000_000, headroomOK: ok, headroomMiB: ok ? headroom : 0, reserveMiB: reserve,
            roomMiB: ok ? room : 0, jobs: jobs.enumerated().map { SampleLine.Job(hold: "h\($0.offset)", label: $0.element.0, footprintMiB: $0.element.1) })
    }

    private func at(_ s: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(Self.t0 + s)) }

    private func bucket(_ b: [Series.Bucket], _ s: Int64) -> Series.Bucket? {
        b.first { $0.startNS == (Self.t0 + s) * 1_000_000_000 }
    }

    // Mutation: keep each label's largest footprint across the bucket's samples; the kept point
    // then mixes samples 2, 6 and 8, red.
    @Test func aBucketKeepsTheWholeSampleWithTheMostMemoryInUse() throws {
        var series = Series(range: .hour)
        let headrooms: [Int64] = [5000, 4900, 4950, 4800, 4700, 4750, 4200, 4600, 4650, 4900]
        for i in 0..<10 {
            let a: Int64 = i == 2 ? 900 : 300, b: Int64 = i == 8 ? 800 : 200
            series.add(sample(Int64(i), headroom: headrooms[i], reserve: 256 + Int64(i), room: 3000 - Int64(i), [("a", a), ("b", b)]))
        }
        let got = try #require(bucket(series.buckets(machineMiB: Self.machine, now: at(10)), 0)?.point)
        #expect(got == Series.Point(
            timeNS: (Self.t0 + 6) * 1_000_000_000, inUseMiB: Self.machine - 4200, footprintMiB: ["a": 300, "b": 200],
            outsideMiB: Self.machine - 4200 - 500, reservedMiB: Self.machine - 262 - 2994))
    }

    // Mutation: keep a failed sample like any other; its headroom of 0 is the most memory in use,
    // and the bucket draws the whole machine as used, red.
    @Test func aFailedReadingIsAGapNotAZero() throws {
        var series = Series(range: .hour)
        for s in 0..<20 { series.add(sample(Int64(s), ok: s != 5)) }
        let b = series.buckets(machineMiB: Self.machine, now: at(20))
        let failed = try #require(bucket(b, 0))
        #expect(failed.point == nil)
        #expect(bucket(b, 10)?.point?.inUseMiB == Self.machine - 5000)
    }

    // Mutation: record no silence; the buckets of the 20 minutes are left out instead of being
    // gaps, red.
    // Mutation: drop the unrecorded range before the first sample; bucket −10 is left out, red.
    @Test func aTwentyMinuteSilenceIsAGap() {
        var series = Series(range: .hour)
        for s in stride(from: Int64(0), through: 60, by: 2) { series.add(sample(s)) }
        for s in stride(from: Int64(1260), through: 1320, by: 2) { series.add(sample(s)) }
        let b = series.buckets(machineMiB: Self.machine, now: at(1321))
        for s in stride(from: Int64(70), through: 1250, by: 10) {
            #expect(bucket(b, s).map { $0.point == nil } == true, "bucket at +\(s) s")
        }
        #expect(bucket(b, 60)?.point != nil && bucket(b, 1260)?.point != nil)
        #expect(bucket(b, -10).map { $0.point == nil } == true, "nothing was recorded before the first sample")
    }

    // Mutation: ignore a sample earlier than the last (the rule before this one); nothing after
    // the step is kept, red.
    // Mutation: keep what came after a step back; the point at +100 s stays, red.
    @Test func aStepBackDropsWhatCameAfterItAndGoesOn() throws {
        var step = Series(range: .hour), ahead = Series(range: .hour)
        for (s, headroom) in [(0, 5000), (100, 1000), (20, 4000), (30, 3000)] as [(Int64, Int64)] {
            step.add(sample(s, headroom: headroom))
        }
        let b = step.buckets(machineMiB: Self.machine, now: at(110))
        #expect([0, 20, 30, 100].map { bucket(b, $0)?.point?.inUseMiB } == [5000, 4000, 3000].map { Self.machine - $0 } + [nil])
        // A line dated a day ahead is undone by the next sample, which is kept.
        for (s, headroom) in [(0, 5000), (86_400, 1000), (20, 4000), (30, 3000)] as [(Int64, Int64)] {
            ahead.add(sample(s, headroom: headroom))
        }
        let a = ahead.buckets(machineMiB: Self.machine, now: at(40))
        #expect([20, 30].map { bucket(a, $0)?.point?.inUseMiB } == [4000, 3000].map { Self.machine - $0 })
    }

    // Each mutation crashes the run with an overflow trap, red:
    // Mutation: decode `footprint_mib` unclamped (`Int64.max` + 1 for the shared label).
    // Mutation: decode `time_ns` unclamped (`Int64.max` − `Int64.min`).
    // Mutation: decode `room_mib` unclamped (`machine − reserve − Int64.min` in the buckets).
    @Test func integersFromTheStateDirectoryCannotTrap() throws {
        let (max, min) = ("9223372036854775807", "-9223372036854775808")
        let line = { (t: String, room: String, jobs: String) in
            SampleLine(line: Data(#"{"v":1,"time_ns":\#(t),"level":"green","headroom_ok":true,"headroom_mib":2000,"reserve_mib":256,"room_mib":\#(room),"live_holds":2,"jobs":[\#(jobs)]}"#.utf8))
        }
        let early = try #require(line(min, "0", ""))
        let late = try #require(line(max, min, #"{"hold":"a","label":"x","footprint_mib":\#(max)},{"hold":"b","label":"x","footprint_mib":1}"#))
        #expect(early.timeNS == 0 && late.timeNS == 1 << 62 && late.roomMiB == -(1 << 40))
        #expect(late.jobs.map(\.footprintMiB) == [1 << 40, 1])
        var series = Series(range: .hour)
        series.add(early)
        series.add(late)
        let point = try #require(series.buckets(machineMiB: Self.machine, now: Date(timeIntervalSince1970: 0x1p62 / 1e9)).last?.point)
        #expect(point.footprintMiB == ["x": (1 << 40) + 1] && point.reservedMiB == Self.machine - 256 + (1 << 40))
    }
}

@Suite struct ReportTests {
    // Mutation: spell the `longest_s` key `longest`; the fixture no longer decodes, red.
    @Test func theCapturedReportDecodes() throws {
        let report = try JSONDecoder().decode(Report.self, from: Fixture.data("report.json"))
        let raw = try Fixture.object("report.json")
        let waits = try #require(raw["waits"] as? [String: Any])
        #expect(report.runs == (raw["runs"] as? NSNumber)?.int64Value)
        #expect(report.medianWaitS == (waits["median_s"] as? NSNumber)?.doubleValue)
        #expect(report.longestWaitS == (waits["longest_s"] as? NSNumber)?.doubleValue)
        #expect(report.runs > 0)
        // The fixture waited under a second, so both are 0; distinct values tell the keys apart.
        // Mutation: swap the median and longest keys; red here only.
        let waited = try Fixture.data("report.json") { $0["waits"] = waits.merging(["median_s": 12.5, "longest_s": 90]) { $1 } }
        let w = try JSONDecoder().decode(Report.self, from: waited)
        #expect(w.medianWaitS == 12.5 && w.longestWaitS == 90)
        let other = try Fixture.data("report.json") { $0["schema"] = 2 }
        #expect(throws: OtherSchema.self) { try JSONDecoder().decode(Report.self, from: other) }
    }
}

@Suite struct HoldTracksTests {
    private func sample(_ s: Int64, ok: Bool = true, _ jobs: [(String, Int64)]) -> SampleLine {
        SampleLine(
            timeNS: s * 1_000_000_000, headroomOK: ok, headroomMiB: ok ? 4000 : 0, reserveMiB: 256, roomMiB: 0,
            jobs: jobs.map { SampleLine.Job(hold: $0.0, label: "demo:same", footprintMiB: $0.1) })
    }

    // Mutation: key the tracks by label, as `Series` does; the two holds of one label merge, red.
    @Test func twoHoldsOfOneLabelAreTwoTracks() {
        var t = HoldTracks()
        t.add(sample(1000, [("h1", 100), ("h2", 700)]))
        t.add(sample(1012, [("h1", 150), ("h2", 650)]))
        #expect(t.points("h1").map(\.footprintMiB) == [100, 150])
        #expect(t.peak("h1") == 150 && t.peak("h2") == 700)
    }

    // Mutation: drop the `headroomOK` guard; the failed sample's 0 becomes a point, red.
    @Test func aFailedSampleIsAGapNotZero() {
        var t = HoldTracks()
        t.add(sample(1000, [("h1", 300)]))
        t.add(sample(1020, ok: false, [("h1", 0)]))
        #expect(t.points("h1").map(\.footprintMiB) == [300])
    }

    // Mutation: append instead of inserting in time order; the older line lands last, red.
    @Test func aBucketKeepsItsLargestAndLinesArriveOutOfOrder() {
        var t = HoldTracks(resolutionS: 10, spanS: 60)
        t.add(hold: "h", timeNS: 1_020_000_000_000, footprintMiB: 50)
        t.add(hold: "h", timeNS: 1_000_000_000_000, footprintMiB: 40)
        t.add(hold: "h", timeNS: 1_021_000_000_000, footprintMiB: 80)
        t.add(hold: "h", timeNS: 1_022_000_000_000, footprintMiB: 60)
        #expect(t.points("h").map(\.footprintMiB) == [40, 80])
        t.add(hold: "h", timeNS: 1_090_000_000_000, footprintMiB: 10)
        #expect(t.points("h").map(\.footprintMiB) == [10], "a point older than the span is gone")
        t.keep(only: ["other"])
        #expect(t.points("h") == [] && t.peak("h") == nil)
    }
}
