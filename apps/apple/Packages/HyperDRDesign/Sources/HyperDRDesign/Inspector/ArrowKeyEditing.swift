import SwiftUI

/// What a control does with an arrow key: a held key is one editing session.
/// The session opens at the first key-down and stays open through the
/// auto-repeat; key-up, focus leaving, the control being disabled or removed
/// close it (`finish`, idempotent). Every step inside it is part of one undo
/// step; a single press is a session of its own. Nothing here guesses from
/// timing.
struct ArrowKeyEditing {
    private(set) var session = EditingBracket()

    var isOpen: Bool { session.isOpen }

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

    mutating func finish(_ notify: (Bool) -> Void) { session.finish(notify) }
}
