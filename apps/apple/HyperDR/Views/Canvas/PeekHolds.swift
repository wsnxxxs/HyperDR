/// Who is holding the original. The pointer's press-and-hold and the Space
/// key can both do it; the original goes back to the edit when the last of
/// them lets go, not the first, and Esc or the canvas going away lets go of
/// all of them (a key-up that never arrives, a press that never ends).
///
/// Pure of AppKit, so a test drives it with the two sources and two closures.
@MainActor final class PeekHolds {
    enum Source: Hashable { case pointer, key }

    private let begin: () -> Void
    private let end: () -> Void
    private var held: Set<Source> = []

    init(begin: @escaping () -> Void, end: @escaping () -> Void) {
        self.begin = begin
        self.end = end
    }

    var isHeld: Bool { !held.isEmpty }

    /// `source` holds the original; the first holder begins the peek.
    func hold(_ source: Source) {
        let wasEmpty = held.isEmpty
        held.insert(source)
        if wasEmpty { begin() }
    }

    /// `source` lets go; the last one to do so ends the peek.
    func release(_ source: Source) {
        guard held.remove(source) != nil, held.isEmpty else { return }
        end()
    }

    /// Esc, the window going inactive, focus leaving, or the canvas leaving.
    func releaseAll() {
        guard !held.isEmpty else { return }
        held = []
        end()
    }
}
