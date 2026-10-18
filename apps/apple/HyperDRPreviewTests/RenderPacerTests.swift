import XCTest
@testable import HyperDR

/// A2 / S12: slider changes reach the preview service at most once per display
/// frame, always with the newest value.
@MainActor final class RenderPacerTests: XCTestCase {
    func testPacerKeepsOnlyTheNewestValueUntilAFrameTakesIt() {
        var pacer = RenderPacer<Int>()
        XCTAssertNil(pacer.takeForFrame())
        pacer.update(1)
        pacer.update(2)
        XCTAssertTrue(pacer.isDirty)
        XCTAssertEqual(pacer.takeForFrame(), 2)
        XCTAssertNil(pacer.takeForFrame(), "a frame without a new value submits nothing")
        pacer.update(3)
        pacer.discard()
        XCTAssertNil(pacer.takeForFrame())
    }

    /// The batch 3 criterion on a pure model of one second at 60 Hz: 1000
    /// updates spread over the frames, submissions ≤ frames + 1, and the last
    /// value goes out on the first frame after it.
    func testThousandUpdatesInOneSecondSubmitAtMostOncePerFrame() {
        var pacer = RenderPacer<Int>()
        var submitted: [(frame: Int, value: Int)] = []
        let frames = 60
        var frame = 0
        for value in 1...1000 {
            pacer.update(value)
            // Frame boundaries fall evenly between the updates.
            if value * frames / 1000 > frame {
                frame += 1
                if let next = pacer.takeForFrame() { submitted.append((frame, next)) }
            }
        }
        frame += 1
        if let next = pacer.takeForFrame() { submitted.append((frame, next)) }
        XCTAssertLessThanOrEqual(submitted.count, frames + 1)
        XCTAssertEqual(submitted.last?.value, 1000)
        XCTAssertLessThanOrEqual(submitted.last?.frame ?? Int.max, frames + 1, "the last value goes out by the next frame")
        XCTAssertEqual(Set(submitted.map(\.frame)).count, submitted.count, "never twice in one frame")
    }

    func testSchedulerSubmitsTheNewestValueOncePerFrame() async {
        let ticker = ManualFrameTicker()
        var submitted: [Int] = []
        let scheduler = RenderScheduler<Int>(ticker: ticker) { submitted.append($0) }
        defer { scheduler.cancel() }

        await settle()
        XCTAssertEqual(ticker.waits, 0, "an idle loop waits on updates, not on frames")
        var frames = 0
        for value in 1...1000 {
            scheduler.update(value)
            if value % 16 == 0 {
                await eventually("the loop to wait for a frame") { ticker.isWaiting }
                ticker.tick()
                frames += 1
                await settle()
            }
        }
        await eventually("the loop to wait for the last frame") { ticker.isWaiting }
        ticker.tick()
        frames += 1
        await eventually("the last value") { submitted.last == 1000 }
        XCTAssertLessThanOrEqual(submitted.count, frames + 1)
        XCTAssertEqual(submitted, submitted.sorted(), "values never go back in time")
        XCTAssertFalse(scheduler.hasPending)

        // Idle again: no further frames are consumed and nothing is submitted.
        let count = submitted.count
        await settle()
        ticker.tick()
        await settle()
        XCTAssertEqual(submitted.count, count)
    }

    func testCancelledSchedulerDropsThePendingValueAndStops() async {
        let ticker = ManualFrameTicker()
        var submitted: [Int] = []
        let scheduler = RenderScheduler<Int>(ticker: ticker) { submitted.append($0) }
        scheduler.update(1)
        await eventually("the loop to wait for a frame") { ticker.isWaiting }
        scheduler.cancel()
        await eventually("the waiter to be cancelled") { !ticker.isWaiting }
        ticker.tick()
        scheduler.update(2)
        await settle()
        XCTAssertEqual(submitted, [])
    }

    /// Production pacing against the real clock: one second of 1 ms updates at
    /// 60 Hz. Bounds only, so a loaded machine cannot make it flaky.
    func testClockTickerPacesARealSecondOfUpdates() async throws {
        let ticker = ClockFrameTicker(framesPerSecond: 60)
        var submitted: [Int] = []
        let scheduler = RenderScheduler<Int>(ticker: ticker) { submitted.append($0) }
        defer { scheduler.cancel() }
        let clock = ContinuousClock()
        let started = clock.now
        var value = 0
        while started.duration(to: clock.now) < .seconds(1) {
            value += 1
            scheduler.update(value)
            try await Task.sleep(for: .milliseconds(1))
        }
        let elapsed = started.duration(to: clock.now)
        let last = value
        await eventually("the last value within a frame") { submitted.last == last }
        let lastSubmitted = clock.now
        let frames = Int((elapsed / ticker.frameDuration).rounded(.up))
        XCTAssertLessThanOrEqual(submitted.count, frames + 1)
        XCTAssertLessThan(lastSubmitted - started - elapsed, .milliseconds(250),
                          "the newest value follows within about a frame")
        XCTAssertLessThan(submitted.count, value, "updates were coalesced")
    }
}
