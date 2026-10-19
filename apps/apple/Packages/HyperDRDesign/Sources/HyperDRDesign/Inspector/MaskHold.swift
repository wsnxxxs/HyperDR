/// Why a control asks for its mask to be shown on the photo: the pointer is
/// over its row, its value field has focus, or its thumb is being dragged.
///
/// The mask stays up while any one of them holds it. `set` reports `true`
/// when the first source takes hold and `false` when the last lets go; every
/// other call, and a repeat of the same one, reports nothing, so the model
/// sees one request and one release however the sources overlap.
struct MaskHold {
    enum Source: Hashable, CaseIterable { case hover, focus, drag }

    private(set) var sources: Set<Source> = []

    var isHeld: Bool { !sources.isEmpty }

    mutating func set(_ source: Source, _ on: Bool, notify: (Bool) -> Void) {
        let before = isHeld
        if on { sources.insert(source) } else { sources.remove(source) }
        if isHeld != before { notify(isHeld) }
    }

    /// Lets go of every source: the control was disabled or removed.
    mutating func releaseAll(notify: (Bool) -> Void) {
        guard isHeld else { return }
        sources.removeAll()
        notify(false)
    }
}
