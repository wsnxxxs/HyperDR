/// The begin/end of one pointer drag, with the guarantee that a `begin` is
/// followed by exactly one `end` however the drag stops: finished, cancelled
/// by the system, or the control removed or disabled under it. `finish` is
/// idempotent, so every one of those paths may call it.
struct EditingBracket {
    private(set) var isOpen = false

    /// Reports `true` once per drag; later calls until `finish` do nothing.
    mutating func begin(_ notify: (Bool) -> Void) {
        guard !isOpen else { return }
        isOpen = true
        notify(true)
    }

    /// Reports `false` if a drag is open; otherwise nothing (a secondary click
    /// never began, or the drag already ended).
    mutating func finish(_ notify: (Bool) -> Void) {
        guard isOpen else { return }
        isOpen = false
        notify(false)
    }
}
