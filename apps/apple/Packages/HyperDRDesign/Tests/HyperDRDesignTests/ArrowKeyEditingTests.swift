import SwiftUI
import Testing
@testable import HyperDRDesign

/// A held arrow key is one editing session (batch 4 §2.4): the first
/// key-down begins it, the repeats stay inside it, key-up ends it.
@Test func aHeldArrowKeyIsOneSession() {
    var keys = ArrowKeyEditing()
    var log: [Bool] = []
    var steps: [Int] = []
    for phase in [KeyPress.Phases.down, .repeat, .repeat, .up] {
        if let applied = keys.handle(phase, steps: 1, notify: { log.append($0) }) { steps.append(applied) }
    }
    #expect(log == [true, false])
    #expect(steps == [1, 1, 1], "every down and repeat steps; the key-up does not")
    #expect(!keys.isOpen)
}

@Test func eachSinglePressIsASessionOfItsOwn() {
    var keys = ArrowKeyEditing()
    var log: [Bool] = []
    for _ in 0..<2 {
        _ = keys.handle(.down, steps: -1, notify: { log.append($0) })
        _ = keys.handle(.up, steps: -1, notify: { log.append($0) })
    }
    #expect(log == [true, false, true, false])
}

@Test func focusLeavingTheDisabledControlOrRemovalEndsAHeldKey() {
    var keys = ArrowKeyEditing()
    var log: [Bool] = []
    _ = keys.handle(.down, steps: 1, notify: { log.append($0) })
    _ = keys.handle(.repeat, steps: 1, notify: { log.append($0) })
    keys.finish { log.append($0) }
    keys.finish { log.append($0) }      // idempotent: the removal after the focus loss
    _ = keys.handle(.up, steps: 1, notify: { log.append($0) }) // the key-up that never reaches us
    #expect(log == [true, false])
}

@Test func aKeyUpWithoutASessionReportsNothing() {
    var keys = ArrowKeyEditing()
    var log: [Bool] = []
    #expect(keys.handle(.up, steps: 1, notify: { log.append($0) }) == nil)
    #expect(log.isEmpty)
}
