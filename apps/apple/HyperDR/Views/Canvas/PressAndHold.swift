import CoreGraphics

/// The rule for "hold the photo to see the original" (contract §2.7): the
/// press has to last 240 ms, and a press that moves more than 4 pt before
/// then is a pan and is not a hold. Once a hold has begun, moving does not
/// end it; only letting go does.
///
/// The canvas reports the pointer; this decides. Pure of AppKit, so a test
/// drives it with points and a short delay.
@MainActor final class PressAndHold {
    static let delay: Duration = .milliseconds(240)
    static let tolerance: CGFloat = 4

    private let delay: Duration
    private let begin: () -> Void
    private let end: () -> Void
    private var origin: CGPoint?
    private var timer: Task<Void, Never>?
    private(set) var isHolding = false

    init(delay: Duration = PressAndHold.delay, begin: @escaping () -> Void, end: @escaping () -> Void) {
        self.delay = delay
        self.begin = begin
        self.end = end
    }

    func press(at point: CGPoint) {
        release()
        origin = point
        timer = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, origin != nil else { return }
            timer = nil
            isHolding = true
            begin()
        }
    }

    func drag(to point: CGPoint) {
        guard let origin, timer != nil else { return }
        if hypot(point.x - origin.x, point.y - origin.y) > Self.tolerance { cancelTimer() }
    }

    /// The button went up, or the window stopped being active.
    func release() {
        cancelTimer()
        origin = nil
        if isHolding {
            isHolding = false
            end()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
