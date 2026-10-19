import Observation

/// Which hint the canvas shows now. A hint appears when the first edited
/// frame arrives and when the view mode changes (the model's
/// `viewerHintKey` changes), at most twice per key in a run, and goes after
/// 4 s or at the user's first action on the canvas (design §5).
///
/// Holding the photo to see the original swaps the key to `canvas.peeking`;
/// that is the label's business, not a hint, and when the hold ends the key
/// that was there comes back without being announced again.
@MainActor @Observable final class CanvasHintState {
    private(set) var shown: String?
    @ObservationIgnored private var lastKey: String?
    static let peeking = "canvas.peeking"

    /// `key` is the model's current hint key. While the legend is on the
    /// canvas (`covered`) the hint has no room: it is not shown and not
    /// counted, and is not announced when the legend goes.
    func update(key: String?, session: ViewerSessionState, covered: Bool = false) {
        if key == Self.peeking {
            shown = nil
            return
        }
        guard key != lastKey else { return }
        lastKey = key
        if covered { shown = nil; return }
        if let key, session.claimHint(key) { shown = key } else { shown = nil }
    }

    /// A different photo is on the canvas, even one with the same name that
    /// arrived while the old frame stayed: the hint is announced again.
    func photoChanged(key: String?, session: ViewerSessionState, covered: Bool = false) {
        reset()
        update(key: key, session: session, covered: covered)
    }

    /// A new photo announces itself again.
    func reset() {
        shown = nil
        lastKey = nil
    }

    /// The user pressed, scrolled, pinched or typed on the canvas, or the
    /// 4 s are up.
    func dismiss() {
        if shown != nil { shown = nil }
    }
}
