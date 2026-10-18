import CoreGraphics
import Foundation
import HyperDREngine
import Metal
import QuartzCore

/// What one canvas should show, captured on the main thread. Immutable; the
/// frame is held strongly so its no-copy planes outlive the draw.
nonisolated struct CanvasSnapshot: @unchecked Sendable {
    enum Content {
        case frame(PreviewFrame, original: Bool)
        /// The diagnostic window's 0–8× ramp.
        case synthetic(original: Bool)
        /// No photo: present a transparent drawable once and let go of the frame.
        case empty
    }
    var content: Content
    var transform: CanvasTransform
    var drawableSize: CGSize
    var contentsScale: CGFloat
    /// Increases with every snapshot a canvas hands over.
    var generation: UInt64 = 0
}

/// One serial render executor per canvas (A2b-2, batch3 §14.6). The main
/// thread only hands over snapshots; this loop's own thread waits for
/// drawables, runs both passes and presents, so a compositor that holds on to
/// drawables blocks this thread and never the main one.
///
/// - Newest wins: one pending snapshot slot, overwritten by a newer one.
/// - One draw in flight per canvas: the loop waits for the GPU to finish the
///   previous presentation, then draws whatever is pending at that moment.
/// - `nextDrawable` comes before pass 1, so a missing drawable costs no GPU
///   work; the snapshot is retried a display frame later.
///
/// `CAMetalDisplayLink` was the first choice; offscreen it hands out only the
/// layer's three drawables and then stops (nothing composites them), so it
/// cannot be tested without a window. Pulling on this thread is the tested
/// fallback §14.6 allows; see `build-dev/a2b2-design.md`.
nonisolated final class PreviewRenderLoop: @unchecked Sendable {
    private let renderer: PreviewRenderer
    private let layer: CAMetalLayer
    private let onError: @Sendable (String) -> Void
    private let retryDelay: TimeInterval
    private let condition = NSCondition()
    private let exited = DispatchSemaphore(value: 0)

    // Guarded by `condition`.
    private var pending: CanvasSnapshot?
    private var stopping = false
    private var rendering = false
    private var lastPresented: UInt64 = 0
    private var presentedOutOfOrder = false
    private var presentations = 0
    // Render thread only.
    private var synthetic: FramePlanes?
    private var showsEmpty = false

    init(renderer: PreviewRenderer, layer: CAMetalLayer, retryDelay: TimeInterval = 0.008,
         onError: @escaping @Sendable (String) -> Void) {
        self.renderer = renderer
        self.layer = layer
        self.retryDelay = retryDelay
        self.onError = onError
        renderer.onPresentationCompleted = { [weak self] in self?.wake() }
        let thread = Thread { [self] in run() }
        thread.name = "com.hyperdr.canvas-render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Main thread: replaces any snapshot not yet drawn. Never blocks beyond
    /// the lock, which the render thread holds only for bookkeeping.
    func submit(_ snapshot: CanvasSnapshot) {
        condition.lock()
        if pending != nil { PreviewRenderer.signposter.emitEvent("Coalesced", id: renderer.signpostID) }
        pending = snapshot
        condition.signal()
        condition.unlock()
    }

    /// Asks the thread to finish its current step and exit; does not wait.
    /// The loop keeps the layer alive until then.
    func stop() {
        condition.lock()
        stopping = true
        pending = nil
        condition.signal()
        condition.unlock()
    }

    /// Tests: waits for the thread to exit after `stop()`.
    func waitUntilStopped(timeout: TimeInterval) -> Bool {
        exited.wait(timeout: .now() + timeout) == .success
    }

    /// Tests and diagnostics, read under the lock.
    struct State {
        var lastPresented: UInt64
        var presentations: Int
        var presentedOutOfOrder: Bool
        var idle: Bool
    }
    var state: State {
        condition.lock()
        defer { condition.unlock() }
        return State(lastPresented: lastPresented, presentations: presentations,
                     presentedOutOfOrder: presentedOutOfOrder,
                     idle: pending == nil && !rendering && renderer.inFlight == 0)
    }

    /// Tests: the renderer's frame cache, read only while the loop is idle.
    var readyFrameIdentity: ObjectIdentifier? {
        condition.lock()
        defer { condition.unlock() }
        return renderer.readyFrameIdentity
    }

    private func wake() {
        condition.lock()
        condition.signal()
        condition.unlock()
    }

    private func run() {
        var retryAt: Date?
        while true {
            condition.lock()
            while !stopping {
                if let deadline = retryAt {
                    // Woken early (new snapshot, completion): keep waiting out
                    // the retry delay unless stopping.
                    if condition.wait(until: deadline) { continue }
                    retryAt = nil
                }
                if pending != nil, renderer.inFlight == 0 { break }
                condition.wait()
            }
            if stopping {
                condition.unlock()
                break
            }
            let snapshot = pending!
            pending = nil
            rendering = true
            condition.unlock()

            let presented = render(snapshot)

            condition.lock()
            rendering = false
            if presented {
                if snapshot.generation < lastPresented { presentedOutOfOrder = true }
                lastPresented = snapshot.generation
                presentations += 1
            } else if pending == nil, !stopping {
                // No drawable: try this snapshot again a frame later, unless a
                // newer one arrived meanwhile.
                pending = snapshot
                retryAt = Date().addingTimeInterval(retryDelay)
            }
            condition.unlock()
        }
        synthetic = nil
        renderer.releaseFrame()
        exited.signal()
    }

    /// Draws one snapshot; false when it must be retried (no drawable).
    private func render(_ snapshot: CanvasSnapshot) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        apply(snapshot)
        do {
            switch snapshot.content {
            case .empty:
                // Repeated empty snapshots (a transform change with no photo)
                // present nothing new.
                if showsEmpty { return true }
                guard renderer.clear(in: layer) else { return false }
                showsEmpty = true
                return true
            case .frame(let frame, let original):
                let drawn = try renderer.draw(in: layer, transform: snapshot.transform) {
                    try renderer.prepare(frame: frame, original: original)
                }
                if drawn { showsEmpty = false }
                return drawn
            case .synthetic(let original):
                let drawn = try renderer.draw(in: layer, transform: snapshot.transform) {
                    if synthetic == nil { synthetic = try PreviewRenderer.syntheticRamp(device: renderer.device) }
                    if let synthetic { try renderer.prepare(planes: synthetic, original: original) }
                }
                if drawn { showsEmpty = false }
                return drawn
            }
        } catch {
            let message = error.localizedDescription
            let report = onError
            DispatchQueue.main.async { report(message) }
            return true   // reported; retrying the same input would fail again
        }
    }

    /// Layer geometry follows the snapshot, set between draws so a drawable
    /// always matches the size the frame was laid out for. This thread has no
    /// run loop, so the change is committed explicitly.
    private func apply(_ snapshot: CanvasSnapshot) {
        guard layer.drawableSize != snapshot.drawableSize
                || layer.contentsScale != snapshot.contentsScale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = snapshot.contentsScale
        layer.drawableSize = snapshot.drawableSize
        CATransaction.commit()
    }
}
