import Observation
import XCTest
@testable import HyperDR

/// The macOS 15 to 25 stand-in for `Observations`, called directly so the
/// newer host exercises it too.
@MainActor final class LegacyObservationsTests: XCTestCase {
    @Observable @MainActor fileprivate final class Box {
        var number = 1
        var other = 0
    }

    func testYieldsTheCurrentValueFirstThenEachChange() async {
        let box = Box()
        var iterator = LegacyObservations.values { box.number }.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, 1)
        box.number = 2
        let second = await iterator.next()
        XCTAssertEqual(second, 2)
        box.number = 3
        let third = await iterator.next()
        XCTAssertEqual(third, 3)
    }

    func testChangesBeforeTheNextReadAreCoalesced() async {
        let box = Box()
        var iterator = LegacyObservations.values { box.number }.makeAsyncIterator()
        _ = await iterator.next()
        box.number = 2
        box.number = 3
        let next = await iterator.next()
        XCTAssertEqual(next, 3)
    }

    func testPropertiesTheReaderDoesNotTouchYieldNothing() async {
        let box = Box()
        var seen: [Int] = []
        let task = Task { @MainActor in
            for await value in LegacyObservations.values({ box.number }) { seen.append(value) }
        }
        await eventually(timeout: .seconds(2)) { seen == [1] }
        box.other = 5
        box.number = 7
        await eventually(timeout: .seconds(2)) { seen == [1, 7] }
        task.cancel()
        await task.value
        XCTAssertEqual(seen, [1, 7])
    }

    func testCancellingTheConsumerEndsTheLoop() async {
        let box = Box()
        let started = expectation(description: "first value")
        let task = Task { @MainActor in
            var count = 0
            for await _ in LegacyObservations.values({ box.number }) {
                count += 1
                if count == 1 { started.fulfill() }
                if Task.isCancelled { break }
            }
            return count
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let count = await task.value
        XCTAssertEqual(count, 1)
        // Changes after the end must not touch anything.
        box.number = 9
    }
}
