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
            timeNS: (Self.t0 + s) * 1_000_000_000, level: ok ? "green" : "unknown", headroomOK: ok,
            headroomMiB: ok ? headroom : 0, reserveMiB: reserve, roomMiB: ok ? room : 0, liveHolds: Int64(jobs.count),
            jobs: jobs.enumerated().map { SampleLine.Job(hold: "h\($0.offset)", label: $0.element.0, footprintMiB: $0.element.1) })
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

    // Mutation: compute the reserved line as `machine − room`; red.
    @Test func theReservedLineIsMachineLessReserveLessRoomOfTheKeptSample() throws {
        var series = Series(range: .quarterHour)
        series.add(sample(0, headroom: 6000, reserve: 1024, room: 2500, [("a", 1000)]))
        series.add(sample(1, headroom: 7000, reserve: 512, room: 4000))
        let got = try #require(bucket(series.buckets(machineMiB: Self.machine, now: at(2)), 0)?.point)
        #expect(got.reservedMiB == Self.machine - 1024 - 2500)
        #expect(got.inUseMiB == Self.machine - 6000 && got.outsideMiB == Self.machine - 6000 - 1000)
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
    @Test func aTwentyMinuteSilenceIsAGap() {
        var series = Series(range: .hour)
        for s in stride(from: Int64(0), through: 60, by: 2) { series.add(sample(s)) }
        for s in stride(from: Int64(1260), through: 1320, by: 2) { series.add(sample(s)) }
        let b = series.buckets(machineMiB: Self.machine, now: at(1321))
        for s in stride(from: Int64(70), through: 1250, by: 10) {
            #expect(bucket(b, s).map { $0.point == nil } == true, "bucket at +\(s) s")
        }
        #expect(bucket(b, 60)?.point != nil && bucket(b, 1260)?.point != nil)
        #expect(bucket(b, -10)?.point == nil, "nothing was recorded before the first sample")
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
        var waited = raw
        waited["waits"] = waits.merging(["median_s": 12.5, "longest_s": 90]) { $1 }
        let w = try JSONDecoder().decode(Report.self, from: Fixture.encode(waited))
        #expect(w.medianWaitS == 12.5 && w.longestWaitS == 90)
        var other = raw
        other["schema"] = 2
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Report.self, from: Fixture.encode(other)) }
    }
}
