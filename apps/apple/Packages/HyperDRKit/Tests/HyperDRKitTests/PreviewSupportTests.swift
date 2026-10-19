import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite(.timeLimit(.minutes(1))) struct PreviewSupportTests {
    @Test func singleFlightCoalescesConcurrentCallers() async throws {
        let flight = SingleFlight<String, Int>()
        let calls = Counter(), gate = TestStepGate()
        defer { gate.release() }
        let values = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await flight.run("same") {
                        await calls.increment()
                        await gate.wait()
                        return 7
                    }
                }
            }
            #expect(await supportEventually(timeout: .seconds(10)) { await flight.waiterCount == 4 })
            gate.release()
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
        let calls = Counter(), gate = TestStepGate()
        defer { gate.release() }
        let errors = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await flight.run("error") {
                            await calls.increment()
                            await gate.wait()
                            throw HyperDRError(code: "decode_failed", message: "broken")
                        }
                        return nil
                    } catch let error as HyperDRError { return error.code }
                    catch { return "other" }
                }
            }
            #expect(await supportEventually(timeout: .seconds(10)) { await flight.waiterCount == 1 })
            gate.release()
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
        do {
            _ = try await gate.acquire(timeout: .milliseconds(50))
            Issue.record("Expected raw_budget")
        } catch let error as HyperDRError {
            #expect(error.code == "raw_budget")
        }
        // The timeout fired while the first ticket was still held. Its timer
        // deadline is not an upper bound on OS/executor scheduling latency.
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
        let calls = Counter(), gate = TestStepGate()
        defer { gate.release() }
        let leader = Task {
            try await flight.run("key") {
                await calls.increment()
                await gate.wait()
                return 7
            }
        }
        defer { leader.cancel() }
        try #require(await supportEventually(timeout: .seconds(10)) { gate.entered })
        let follower = Task { try await flight.run("key") { 9 } }
        defer { follower.cancel() }
        try #require(await supportEventually(timeout: .seconds(10)) { await flight.waiterCount == 1 })
        follower.cancel()
        do {
            _ = try await follower.value
            Issue.record("Expected the follower to be cancelled")
        } catch is CancellationError {
        }
        #expect(await flight.waiterCount == 0)
        #expect(await flight.inFlight == 1, "the leader is still parked, not cancelled")
        gate.release()
        #expect(try await leader.value == 7)
        #expect(await calls.value == 1)
    }

}

extension PreviewSupportTests {
    @Test(.timeLimit(.minutes(1))) func differentSingleFlightKeysRemainIndependent() async throws {
        let flight = SingleFlight<String, Int>()
        let latch = KeyFlightLatch()
        let first = Task { try await flight.run("a") { await latch.wait(); return 1 } }
        defer { Task { await latch.release() } }
        #expect(await supportEventually(timeout: .seconds(10)) { await latch.started })
        // If keys were accidentally coalesced, this receives 1 or times out
        // while the first operation is deliberately parked.
        let second = Task { try await flight.run("b") { await latch.setSecond(); return 2 } }
        #expect(await supportEventually(timeout: .seconds(10)) { await latch.second })
        await latch.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(await flight.inFlight == 0)
    }
}
private actor KeyFlightLatch {
    private var parked: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var second = false
    func wait() async { await withCheckedContinuation { parked = $0; started = true } }
    func setSecond() { second = true }
    func release() { parked?.resume(); parked = nil }
}
private func supportEventually(timeout: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
