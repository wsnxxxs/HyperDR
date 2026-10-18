import Foundation

/// The pending-render slot behind `EditorModel.adjust` (A2, S12): every call
/// overwrites the latest value, and a display frame takes it at most once.
/// Purely synchronous so the coalescing rule is testable without a clock.
struct RenderPacer<Value> {
    private var pending: Value?

    var isDirty: Bool { pending != nil }

    /// Replaces whatever has not been submitted yet.
    mutating func update(_ value: Value) { pending = value }

    /// The value to submit on this frame, or nil when nothing changed since
    /// the last one.
    mutating func takeForFrame() -> Value? {
        defer { pending = nil }
        return pending
    }

    mutating func discard() { pending = nil }
}

/// Paces submissions to display frames. `nextFrame()` returns at the next
/// frame boundary after the previous one it returned.
@MainActor protocol FrameTicker: AnyObject {
    func nextFrame() async throws
}

/// Production pacing: one frame of the canvas's screen after the previous
/// submission, from `ContinuousClock`. It does not need a visible window or a
/// display link, so it also paces renders while the canvas is hidden.
@MainActor final class ClockFrameTicker: FrameTicker {
    /// Updated by the canvas from its screen's `maximumFramesPerSecond`.
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

/// The resident per-document render loop. `update` only writes the pending
/// slot and signals; the loop waits on that signal while idle (no polling),
/// then on the next frame submits the newest value, at most once per frame.
@MainActor final class RenderScheduler<Value> {
    private var pacer = RenderPacer<Value>()
    private let signal: AsyncStream<Void>.Continuation
    private var loop: Task<Void, Never>?

    init(ticker: any FrameTicker, submit: @escaping @MainActor (Value) -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self,
            bufferingPolicy: .bufferingNewest(1))
        signal = continuation
        loop = Task { [weak self] in
            for await _ in stream {
                do { try await ticker.nextFrame() } catch { return }
                guard !Task.isCancelled else { return }
                guard let value = self?.pacer.takeForFrame() else { continue }
                submit(value)
            }
        }
    }

    deinit {
        signal.finish()
        loop?.cancel()
    }

    var hasPending: Bool { pacer.isDirty }

    func update(_ value: Value) {
        pacer.update(value)
        signal.yield()
    }

    /// Drops the pending value; the loop stays alive for later updates.
    func discard() { pacer.discard() }

    /// Ends the loop for good (document closed or replaced).
    func cancel() {
        pacer.discard()
        signal.finish()
        loop?.cancel()
        loop = nil
    }
}
