#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

/// An arrow key event as the controls read it: which phase, which arrow,
/// and whether Shift is down. Built from SwiftUI's `KeyPress` in the views,
/// and from an `NSEvent` in tests, which cannot construct a `KeyPress`.
public struct ArrowKeyInput: Equatable {
    var phase: KeyPress.Phases
    var key: KeyEquivalent
    var shift: Bool

    init(phase: KeyPress.Phases, key: KeyEquivalent, shift: Bool) {
        self.phase = phase
        self.key = key
        self.shift = shift
    }

    init(_ press: KeyPress) {
        self.init(phase: press.phase, key: press.key, shift: press.modifiers.contains(.shift))
    }

    #if canImport(AppKit)
    /// A key-down (or its auto-repeat) or key-up of an arrow key; nil for
    /// anything else.
    public init?(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let key: KeyEquivalent
        switch event.keyCode {
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        default: return nil
        }
        let phase: KeyPress.Phases = event.type == .keyUp ? .up : (event.isARepeat ? .repeat : .down)
        self.init(phase: phase, key: key, shift: event.modifierFlags.contains(.shift))
    }
    #endif

    /// The steps this key asks for: right and up add, left and down take
    /// away, Shift makes it ten. Nil for a horizontal arrow when the control
    /// takes only the vertical ones.
    public func steps(verticalOnly: Bool) -> Int? {
        let direction: Int
        switch key {
        case .upArrow: direction = 1
        case .downArrow: direction = -1
        case .rightArrow where !verticalOnly: direction = 1
        case .leftArrow where !verticalOnly: direction = -1
        default: return nil
        }
        return direction * (shift ? 10 : 1)
    }
}

/// What a control does with an arrow key: a held key is one editing session.
/// The session opens at the first key-down and stays open through the
/// auto-repeat; key-up, focus leaving, the control being disabled or removed
/// close it (`finish`, idempotent). Every step inside it is part of one undo
/// step; a single press is a session of its own. Nothing here guesses from
/// timing.
public struct ArrowKeyEditing {
    private(set) var session = EditingBracket()

    public init() {}

    public var isOpen: Bool { session.isOpen }

    /// A key event. For a down or repeat, opens the session if it is not
    /// open and returns `steps` for the caller to apply; for an up, closes
    /// it and returns nil.
    mutating func handle(_ phase: KeyPress.Phases, steps: Int, notify: (Bool) -> Void) -> Int? {
        if phase == .up {
            session.finish(notify)
            return nil
        }
        session.begin(notify)
        return steps
    }

    public mutating func finish(_ notify: (Bool) -> Void) { session.finish(notify) }

    /// What a control does with an arrow key, in one place: the session
    /// opens and closes through `notify`, and each down or repeat applies
    /// its steps through `apply`. Returns whether the key was taken. The
    /// views call this and nothing else with a key press.
    @discardableResult
    public mutating func perform(_ input: ArrowKeyInput, verticalOnly: Bool, notify: (Bool) -> Void,
                          apply: (Int) -> Void) -> Bool {
        guard let steps = input.steps(verticalOnly: verticalOnly) else { return false }
        if let applied = handle(input.phase, steps: steps, notify: notify) { apply(applied) }
        return true
    }
}
