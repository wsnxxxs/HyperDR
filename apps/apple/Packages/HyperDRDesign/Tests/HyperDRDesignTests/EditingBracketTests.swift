import Testing
@testable import HyperDRDesign

/// Every begin is answered by exactly one end, on whichever path the drag stops.
private func run(_ steps: (inout EditingBracket, (Bool) -> Void) -> Void) -> [Bool] {
    var bracket = EditingBracket()
    var events: [Bool] = []
    steps(&bracket) { events.append($0) }
    return events
}

@Test func aFinishedDragIsOneBeginAndOneEnd() {
    let events = run { b, n in
        b.begin(n); b.begin(n); b.begin(n)   // every onChanged
        b.finish(n)                          // onEnded
        b.finish(n)                          // onChange(of: live) afterwards
    }
    #expect(events == [true, false])
}

@Test func aCancelledGestureStillEnds() {
    // No onEnded: only the GestureState reset reaches finish.
    let events = run { b, n in b.begin(n); b.finish(n) }
    #expect(events == [true, false])
}

@Test func aControlRemovedMidDragEndsOnDisappear() {
    let events = run { b, n in b.begin(n); b.finish(n) /* onDisappear */; b.finish(n) /* late onEnded */ }
    #expect(events == [true, false])
}

@Test func aDragThatNeverBeganSendsNothing() {
    #expect(run { b, n in b.finish(n) } == [])   // secondary click
}

@Test func theNextDragAfterACancelBeginsAgain() {
    let events = run { b, n in b.begin(n); b.finish(n); b.begin(n); b.finish(n) }
    #expect(events == [true, false, true, false])
}
