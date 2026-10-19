import Testing
@testable import HyperDRDesign

private func run(_ steps: (inout MaskHold, (Bool) -> Void) -> Void) -> [Bool] {
    var hold = MaskHold()
    var events: [Bool] = []
    steps(&hold) { events.append($0) }
    return events
}

@Test func theFirstSourceAsksAndTheLastOneReleases() {
    let events = run { h, n in
        h.set(.hover, true, notify: n)
        h.set(.drag, true, notify: n)    // already held: nothing
        h.set(.hover, false, notify: n)  // the drag still holds it
        h.set(.drag, false, notify: n)
    }
    #expect(events == [true, false])
}

@Test func repeatsAreIdempotent() {
    let events = run { h, n in
        h.set(.focus, true, notify: n)
        h.set(.focus, true, notify: n)
        h.set(.focus, false, notify: n)
        h.set(.focus, false, notify: n)
        h.set(.hover, false, notify: n)  // never held
    }
    #expect(events == [true, false])
}

@Test func disablingOrRemovingReleasesWhateverIsHeld() {
    let events = run { h, n in
        h.set(.hover, true, notify: n)
        h.set(.focus, true, notify: n)
        h.set(.drag, true, notify: n)
        h.releaseAll(notify: n)
        h.releaseAll(notify: n)
    }
    #expect(events == [true, false])
}

@Test func releasingWhenNothingIsHeldReportsNothing() {
    #expect(run { h, n in h.releaseAll(notify: n) }.isEmpty)
}
