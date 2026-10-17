import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite struct PreviewSupportTests {
    @Test func singleFlightCoalescesConcurrentCallers() async throws {
        let flight = SingleFlight<String, Int>()
        let calls = Counter()
        let values = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await flight.run("same") {
                        await calls.increment()
                        try await Task.sleep(for: .milliseconds(50))
                        return 7
                    }
                }
            }
            var result: [Int?] = []
            for await value in group { result.append(value) }
            return result
        }
        #expect(await calls.value == 1)
        #expect(values == [7, 7, 7, 7, 7])
        #expect(await flight.inFlight == 0)
    }

    @Test func singleFlightSharesLeaderFailureAndReleasesKey() async throws {
        let flight = SingleFlight<String, Int>()
        let calls = Counter()
        let errors = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await flight.run("error") {
                            await calls.increment()
                            try await Task.sleep(for: .milliseconds(50))
                            throw HyperDRError(code: "decode_failed", message: "broken")
                        }
                        return nil
                    } catch let error as HyperDRError { return error.code }
                    catch { return "other" }
                }
            }
            var result: [String?] = []
            for await value in group { result.append(value) }
            return result
        }
        #expect(await calls.value == 1)
        #expect(errors == ["decode_failed", "decode_failed"])
        #expect(await flight.inFlight == 0)
        #expect(try await flight.run("error") { 9 } == 9)
    }

    @Test func rawGateTimesOutAndReturnsSlots() async throws {
        let gate = RawDecodeGate(slots: 1)
        let first = try await gate.acquire(timeout: .seconds(1))
        let start = ContinuousClock.now
        do {
            _ = try await gate.acquire(timeout: .milliseconds(50))
            Issue.record("Expected raw_budget")
        } catch let error as HyperDRError {
            #expect(error.code == "raw_budget")
        }
        #expect(start.duration(to: .now) < .milliseconds(500))
        await first.release()
        let second = try await gate.acquire(timeout: .milliseconds(500))
        await second.release()
        let third = try await gate.acquire(timeout: .milliseconds(500))
        await third.release()
    }

    @Test func previewCacheIsLRUByCountAndBytes() async {
        let cache = PreviewCache<String, Int>(entries: 2, bytes: 10)
        await cache.put(1, bytes: 4, for: "a")
        await cache.put(2, bytes: 4, for: "b")
        #expect(await cache.get("a") == 1)
        await cache.put(3, bytes: 4, for: "c")
        #expect(await cache.get("a") == 1)
        #expect(await cache.get("b") == nil)
        #expect(await cache.get("c") == 3)
        #expect(await cache.count == 2)
        #expect(await cache.totalBytes == 8)

        let small = PreviewCache<String, Int>(entries: 2, bytes: 6)
        await small.put(1, bytes: 4, for: "a")
        await small.put(2, bytes: 4, for: "b")
        #expect(await small.get("a") == nil)
        #expect(await small.get("b") == 2)
        await small.put(3, bytes: 20, for: "too-large")
        #expect(await small.get("too-large") == nil)
    }

    @Test func singleFlightFollowerCancellationDoesNotCancelTheLeader() async throws {
        let flight = SingleFlight<String, Int>()
        let calls = Counter()
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let leader = Task {
            try await flight.run("key") {
                await calls.increment()
                signal.yield()
                try await Task.sleep(for: .milliseconds(120))
                return 7
            }
        }
        for await _ in started { break }
        let follower = Task { try await flight.run("key") { 9 } }
        try await Task.sleep(for: .milliseconds(20))
        follower.cancel()
        do {
            _ = try await follower.value
            Issue.record("Expected the follower to be cancelled")
        } catch is CancellationError {
        }
        #expect(try await leader.value == 7)
        #expect(await calls.value == 1)
    }
}
