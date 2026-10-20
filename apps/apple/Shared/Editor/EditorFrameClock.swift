import Foundation

/// Paces preview renders to display frames: `nextFrame()` returns at the next
/// frame boundary after the previous one it returned (p7-2b §2).
@MainActor protocol EditorFrameClock: AnyObject {
    func nextFrame() async throws
}

/// One frame of the canvas's screen after the previous submission, from
/// `ContinuousClock`; needs no display link, so it also paces renders while
/// the canvas is hidden.
@MainActor final class ContinuousFrameClock: EditorFrameClock {
    /// Updated by the canvas from its screen's maximum frame rate.
    var framesPerSecond: Int {
        didSet { framesPerSecond = max(1, framesPerSecond) }
    }

    private let clock = ContinuousClock()
    private var lastFrame: ContinuousClock.Instant?

    init(framesPerSecond: Int = 120) {
        self.framesPerSecond = max(1, framesPerSecond)
    }

    var frameDuration: Duration { .seconds(1) / framesPerSecond }

    func nextFrame() async throws {
        if let lastFrame {
            let deadline = lastFrame + frameDuration
            if clock.now < deadline { try await clock.sleep(until: deadline) }
        }
        lastFrame = clock.now
    }
}
