import CoreslotKit
import Foundation
import Synchronization
import Testing
@testable import CoreslotMenubar

/// The rule that `status --docker` is asked only while the popover or the timeline is open lives
/// in `Store.ingest`, so it is tested there, over a fake `coreslot`.
@MainActor @Suite struct StoreDockerTests {
    private final class Count: Sendable {
        private let n = Mutex(0)
        func add() { n.withLock { $0 += 1 } }
        var value: Int { n.withLock { $0 } }
    }

    private final class Clock: Sendable {
        private let t = Mutex(Date(timeIntervalSince1970: 1_000_000))
        func advance(_ s: TimeInterval) { t.withLock { $0 += s } }
        var now: Date { t.withLock { $0 } }
    }

    private func store(asked: Count, clock: Clock = Clock()) -> Store {
        let runner = Runner { _, args, _, _ in
            switch args.first {
            case "version": return RunResult(exitCode: 0, stdout: Data("coreslot 0.8.0 (protocol formats: 2)".utf8))
            case "status" where args.contains("--docker"):
                asked.add()
                return RunResult(exitCode: 0, stdout: Data(#"{"schema":1,"docker":{"state":"other_engine","reason":"","vm":{"mem_mib":null,"identified":false,"footprint_mib":null},"free_est_mib":null,"containers":[]}}"#.utf8))
            case "status": return RunResult(exitCode: 0, stdout: Data(#"{"schema":2}"#.utf8))
            default: return RunResult(exitCode: 64)
            }
        }
        // The fake never runs the file; it only has to exist.
        return Store(feed: Feed(find: { _ in URL(filePath: "/bin/sh") }, runner: runner, stateDir: FileManager.default.temporaryDirectory, clock: { clock.now }))
    }

    private func waitFor(_ what: String, _ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(done(), "\(what)")
    }

    // Mutation: call `refreshDocker()` outside `if !visible.isEmpty` in `ingest`; the hidden app asks, red.
    @Test func itAsksOnlyWhileASurfaceIsVisible() async {
        let asked = Count()
        let store = store(asked: asked)
        store.start()
        await waitFor("the first reading") { store.reading != nil }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(asked.value == 0 && store.docker == nil, "hidden")
        store.setVisible(.popover, true)
        await waitFor("the Docker reading") { store.docker != nil }
        #expect(asked.value == 1)
    }

    // Mutation: return `docker` from `dockerShown` without `DockerSource.shown`, or leave `dockerAt`
    // unset when the reading lands; the ten-minute-old reading is drawn, or none is, red.
    @Test func aReadingFromBeforeThePopoverClosedIsNotDrawn() async {
        let (asked, clock) = (Count(), Clock())
        let store = store(asked: asked, clock: clock)
        store.start()
        await waitFor("the first reading") { store.reading != nil }
        store.setVisible(.popover, true)
        await waitFor("the Docker reading") { store.dockerShown != nil }
        store.setVisible(.popover, false)
        clock.advance(10 * 60)
        #expect(store.docker != nil && store.dockerShown == nil, "ten minutes old")
    }
}
