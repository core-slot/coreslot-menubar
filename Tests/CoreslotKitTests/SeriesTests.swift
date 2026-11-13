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
            series.add(sample(Int64(i), headroom: headrooms[i], reserve: 256 + Int64(i), room: 3000 - Int64(i), [("a", a), ("b", b)]), now: at(10))
        }
        let got = try #require(bucket(series.buckets(machineMiB: Self.machine, now: at(10)), 0)?.point)
        #expect(got == Series.Point(
            timeNS: (Self.t0 + 6) * 1_000_000_000, inUseMiB: Self.machine - 4200, footprintMiB: ["a": 300, "b": 200],
            outsideMiB: Self.machine - 4200 - 500, reservedMiB: Self.machine - 262 - 2994))
    }

    // Mutation: drop the failed slots' check in `buckets`; bucket 0 draws its other samples, red.
    @Test func aFailedReadingIsAGapNotAZero() throws {
        var series = Series(range: .hour)
        for s in 0..<20 { series.add(sample(Int64(s), ok: s != 5), now: at(20)) }
        let b = series.buckets(machineMiB: Self.machine, now: at(20))
        let failed = try #require(bucket(b, 0))
        #expect(failed.point == nil)
        #expect(bucket(b, 10)?.point?.inUseMiB == Self.machine - 5000)
    }

    // Mutation: a run of empty slots is never a gap (`run[$0] > Int.max`); the buckets of the
    // 20 minutes, and those before the first sample, are left out instead, red.
    @Test func aTwentyMinuteSilenceIsAGap() {
        var series = Series(range: .hour)
        for s in stride(from: Int64(0), through: 60, by: 2) { series.add(sample(s), now: at(1321)) }
        for s in stride(from: Int64(1260), through: 1320, by: 2) { series.add(sample(s), now: at(1321)) }
        let b = series.buckets(machineMiB: Self.machine, now: at(1321))
        for s in stride(from: Int64(70), through: 1250, by: 10) {
            #expect(bucket(b, s).map { $0.point == nil } == true, "bucket at +\(s) s")
        }
        #expect(bucket(b, 60)?.point != nil && bucket(b, 1260)?.point != nil)
        #expect(bucket(b, -10).map { $0.point == nil } == true, "nothing was recorded before the first sample")
    }

    private func points(_ b: [Series.Bucket], _ from: Int64, _ through: Int64) -> [Int64?] {
        stride(from: from, through: through, by: 10).map { bucket(b, $0)?.point?.inUseMiB }
    }

    // The wall clock steps back 300 s after a 20-minute silence: the samples dated 1022…1082 come
    // after those dated 1260…1320, and each is placed by its time, whatever the order.
    // Mutation: between equal samples keep the first that came (`r.headroomMiB < $0.headroomMiB`);
    // the shuffled series keeps other samples, red.
    @Test func aStepBackAcrossASilenceLosesNothing() {
        let times = Array(stride(from: Int64(0), through: 60, by: 2)) + Array(stride(from: Int64(1260), through: 1320, by: 2))
            + Array(stride(from: Int64(1022), through: 1082, by: 2))
        var arrived = Series(range: .hour), shuffled = Series(range: .hour)
        for (i, s) in times.enumerated() { arrived.add(sample(s), now: at(i < 62 ? 1321 : 1083)) }
        for s in times.shuffled() { shuffled.add(sample(s), now: at(1321)) }
        let b = arrived.buckets(machineMiB: Self.machine, now: at(1321))
        let used = Self.machine - 5000
        #expect(points(b, 0, 60) == Array(repeating: used, count: 7))
        #expect(points(b, 1020, 1080) == Array(repeating: used, count: 7))
        #expect(points(b, 1260, 1320) == Array(repeating: used, count: 7))
        #expect(stride(from: Int64(70), through: 1010, by: 10).allSatisfy { bucket(b, $0).map { $0.point == nil } == true })
        #expect(stride(from: Int64(1090), through: 1250, by: 10).allSatisfy { bucket(b, $0).map { $0.point == nil } == true })
        #expect(shuffled.buckets(machineMiB: Self.machine, now: at(1321)) == b)
    }

    // Mutation: drop the `aheadNS` bound; the last line a day ahead is drawn once that day comes, red.
    @Test func aLineDatedADayAheadIsNotPlacedAndCostsNothing() {
        var series = Series(range: .hour)
        for s in stride(from: Int64(0), through: 100, by: 2) {
            series.add(sample(s), now: at(101))
            if s == 50 || s == 100 { series.add(sample(86_400, headroom: 1000), now: at(101)) }
        }
        let b = series.buckets(machineMiB: Self.machine, now: at(101))
        #expect(points(b, 0, 100) == Array(repeating: Self.machine - 5000, count: 11))
        #expect(series.buckets(machineMiB: Self.machine, now: at(86_401)).allSatisfy { $0.point == nil })
    }

    // A line dated 600 s back lands in its own bucket; one dated two days back, before the span,
    // is not placed. Neither changes what came before or after it.
    // Mutation: place by the bucket of `now` instead of the sample's time; red.
    // Mutation: drop the bound at the span's start; the line two days back is kept, red.
    @Test func aLineDatedInThePastIsPlacedByItsTime() {
        var series = Series(range: .hour)
        for s in stride(from: Int64(0), through: 100, by: 2) {
            series.add(sample(s), now: at(101))
            if s == 50 { series.add(sample(-600, headroom: 1000), now: at(101)) }
        }
        series.add(sample(-172_800, headroom: 500), now: at(101))
        let b = series.buckets(machineMiB: Self.machine, now: at(101))
        #expect(points(b, 0, 100) == Array(repeating: Self.machine - 5000, count: 11))
        #expect(bucket(b, -600)?.point?.inUseMiB == Self.machine - 1000)
        #expect(bucket(b, -610)?.point == nil && bucket(b, -590)?.point == nil)
        #expect(series.kept.count == 12)
    }

    // Mutation: never prune; a day of samples keeps a day of buckets, red.
    @Test func aDayOfSamplesKeepsAboutOneSpan() {
        var series = Series(range: .hour)
        for s in stride(from: Int64(0), to: 86_400, by: 10) { series.add(sample(s), now: at(s)) }
        #expect(series.kept.count <= 361 && series.presence.count <= 2 * 361 * 5 / 32 + 2)
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
        let now = Date(timeIntervalSince1970: 0x1p62 / 1e9)
        series.add(early, now: now)
        series.add(late, now: now)
        let point = try #require(series.buckets(machineMiB: Self.machine, now: now).last?.point)
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

    private func at(_ s: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    private func add(_ t: inout HoldTracks, _ s: Int64, _ footprint: Int64, now: Int64) {
        t.add(hold: "h", timeNS: s * 1_000_000_000, footprintMiB: footprint, now: at(now))
    }

    // Mutation: key the tracks by label, as `Series` does; the two holds of one label merge, red.
    @Test func twoHoldsOfOneLabelAreTwoTracks() {
        var t = HoldTracks()
        t.add(sample(1000, [("h1", 100), ("h2", 700)]), now: at(1000))
        t.add(sample(1012, [("h1", 150), ("h2", 650)]), now: at(1012))
        #expect(t.points("h1").map(\.footprintMiB) == [100, 150])
        #expect(t.peak("h1") == 150 && t.peak("h2") == 700)
    }

    // Mutation: drop the `headroomOK` guard; the failed sample's 0 becomes a point, red.
    @Test func aFailedSampleIsAGapNotZero() {
        var t = HoldTracks()
        t.add(sample(1000, [("h1", 300)]), now: at(1000))
        t.add(sample(1020, ok: false, [("h1", 0)]), now: at(1020))
        #expect(t.points("h1").map(\.footprintMiB) == [300])
    }

    // Mutation: append instead of inserting in time order; the older line lands last, red.
    @Test func aBucketKeepsItsLargestAndLinesArriveOutOfOrder() {
        var t = HoldTracks(resolutionS: 10, spanS: 60)
        add(&t, 1020, 50, now: 1020)
        add(&t, 1000, 40, now: 1020)
        add(&t, 1021, 80, now: 1021)
        add(&t, 1022, 60, now: 1022)
        #expect(t.points("h").map(\.footprintMiB) == [40, 80])
        add(&t, 1090, 10, now: 1090)
        #expect(t.points("h").map(\.footprintMiB) == [10], "a point older than the span is gone")
        t.keep(only: ["other"])
        #expect(t.points("h") == [] && t.peak("h") == nil)
    }

    // A line dated a day ahead, mid-run and last, is not placed, and the track goes on.
    // Mutation: the old rule, every line placed and the track pruned from its newest point
    // (`(t.last?.timeNS ?? timeNS) - spanNS`); the first line a day ahead empties the track, red.
    // Mutation: drop the `aheadNS` bound in `placed`; the last line a day ahead is the peak, red.
    @Test func aLineDatedADayAheadIsNotPlacedAndCostsNothing() {
        var t = HoldTracks()
        for s in stride(from: Int64(1000), through: 1100, by: 10) {
            add(&t, s, 100 + s - 1000, now: s)
            if s == 1050 || s == 1100 { add(&t, s + 86_400, 9000, now: s) }
        }
        #expect(t.points("h").map(\.footprintMiB) == Array(stride(from: Int64(100), through: 200, by: 10)))
        #expect(t.peak("h") == 200)
    }

    // The wall clock steps back 5 min, inside the span: both stretches are kept, in time order.
    // Then it steps back an hour, past the span: what comes next is placed by its time, and what
    // is now an hour ahead is dropped. A line dated before the span is not placed.
    // Mutation: prune from the newest point instead of around now; after the hour's step back
    // nothing new is kept, red.
    // Mutation: drop the bound at the span's start in `placed`; the line two hours back is kept, red.
    @Test func aStepBackIsPlacedByItsTime() {
        var t = HoldTracks()
        for s in stride(from: Int64(10_000), through: 10_100, by: 10) { add(&t, s, 100, now: s) }
        for s in stride(from: Int64(9_800), through: 9_900, by: 10) { add(&t, s, 200, now: s) }
        #expect(t.points("h").map(\.footprintMiB) == Array(repeating: 200, count: 11) + Array(repeating: 100, count: 11))
        for s in stride(from: Int64(6_300), through: 6_400, by: 10) { add(&t, s, 300, now: s) }
        add(&t, 6_400 - 7_200, 9000, now: 6_400)
        #expect(t.points("h").map(\.footprintMiB) == Array(repeating: 300, count: 11))
    }
}
