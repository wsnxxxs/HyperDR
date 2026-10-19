import AppKit
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

// MARK: - Through the real entry, from key events

private func event(_ type: NSEvent.EventType, keyCode: UInt16, repeating: Bool = false,
                   flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                     characters: "", charactersIgnoringModifiers: "", isARepeat: repeating, keyCode: keyCode)!
}

/// What the views do with a key press is `perform`; driven here from
/// `NSEvent`s (constructed, not delivered), so a held arrow must open the
/// session once, apply each step, and close it on the key-up.
@Test func aHeldArrowEventSequenceOpensOneSessionAndAppliesEveryStep() throws {
    var keys = ArrowKeyEditing()
    var log: [String] = []
    let events = [event(.keyDown, keyCode: 126), event(.keyDown, keyCode: 126, repeating: true),
                  event(.keyDown, keyCode: 126, repeating: true), event(.keyUp, keyCode: 126)]
    for e in events {
        let input = try #require(ArrowKeyInput(e))
        let taken = keys.perform(input, verticalOnly: true, notify: { log.append($0 ? "begin" : "end") },
                                 apply: { log.append("step \($0)") })
        #expect(taken)
    }
    #expect(log == ["begin", "step 1", "step 1", "step 1", "end"])
}

@Test func arrowEventsMapToDirectionAndShift() throws {
    func steps(_ code: UInt16, shift: Bool = false, verticalOnly: Bool = false) throws -> Int? {
        try #require(ArrowKeyInput(event(.keyDown, keyCode: code, flags: shift ? .shift : [])))
            .steps(verticalOnly: verticalOnly)
    }
    #expect(try steps(126) == 1)
    #expect(try steps(125) == -1)
    #expect(try steps(124) == 1)
    #expect(try steps(123, shift: true) == -10)
    #expect(try steps(123, verticalOnly: true) == nil, "the readout takes only up and down")
    #expect(ArrowKeyInput(event(.keyDown, keyCode: 0)) == nil, "other keys are not arrows")
}

@Test func aHorizontalArrowOnTheReadoutIsNotTakenAndOpensNothing() throws {
    var keys = ArrowKeyEditing()
    var log: [String] = []
    let input = try #require(ArrowKeyInput(event(.keyDown, keyCode: 124)))
    let taken = keys.perform(input, verticalOnly: true, notify: { _ in log.append("notify") }, apply: { _ in log.append("step") })
    #expect(!taken)
    #expect(log.isEmpty)
}
