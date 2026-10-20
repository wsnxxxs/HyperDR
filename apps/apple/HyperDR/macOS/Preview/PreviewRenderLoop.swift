import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// What one canvas should show, captured on the main thread. Immutable; the
/// display pairs hold their textures until the draw is done.
nonisolated struct CanvasSnapshot: @unchecked Sendable {
    enum Content {
        case composition(CanvasComposition)
        /// The diagnostic window's 0–8× ramp.
        case synthetic(original: Bool)
        /// No photo: present a transparent drawable once and let go of the frame.
        case empty
        /// Hidden or detached: release prepared textures without acquiring a drawable.
        case suspended
    }
    var content: Content
    var transform: CanvasTransform
    var drawableSize: CGSize
    /// Increases with every snapshot a canvas hands over.
    var generation: UInt64 = 0
}

/// One serial render executor per canvas (A2b-2, batch3 §14.6). The main
/// thread only hands over snapshots; this loop's own thread waits for
/// drawables, rebuilds the layers and presents, so a compositor that holds on to
/// drawables blocks this thread and never the main one.
///
/// - Newest wins: one pending snapshot slot, overwritten by a newer one.
/// - One draw in flight per canvas: the loop waits for the GPU to finish the
///   previous presentation, then draws whatever is pending at that moment.
/// - `nextDrawable` comes before any layer rebuild, so a missing drawable costs no GPU
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
    private var stopped = false
    private var rendering = false
    private var lastPresented: UInt64 = 0
    private var presentedOutOfOrder = false
    private var presentations = 0
    // Render thread only.
    private var synthetic: DisplayPair?
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
        var hasStopped: Bool
    }
    var state: State {
        condition.lock()
        defer { condition.unlock() }
        return State(lastPresented: lastPresented, presentations: presentations,
                     presentedOutOfOrder: presentedOutOfOrder,
                     idle: pending == nil && !rendering && renderer.inFlight == 0, hasStopped: stopped)
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
            if presented, case .suspended = snapshot.content {
                // Resource release is not a presentation.
            } else if presented {
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
        condition.lock()
        stopped = true
        condition.unlock()
        exited.signal()
    }

    /// Draws one snapshot; false when it must be retried (no drawable).
    private func render(_ snapshot: CanvasSnapshot) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        apply(snapshot)
        do {
            switch snapshot.content {
            case .suspended:
                synthetic = nil
                renderer.releaseFrame()
                showsEmpty = false
                return true
            case .empty:
                guard snapshot.drawableSize.width > 0, snapshot.drawableSize.height > 0 else {
                    renderer.releaseFrame()
                    // A zero-size close releases the photo but cannot clear
                    // its last drawable. Clear again when geometry returns.
                    showsEmpty = false
                    return true
                }
                // Repeated empty snapshots (a transform change with no photo)
                // present nothing new.
                if showsEmpty { return true }
                guard renderer.clear(in: layer) else { return false }
                showsEmpty = true
                return true
            case .composition(let content):
                let drawn = try renderer.draw(in: layer, composition: content, transform: snapshot.transform)
                if drawn { showsEmpty = false }
                return drawn
            case .synthetic(let original):
                if synthetic == nil { synthetic = try PreviewRenderer.syntheticRamp(device: renderer.device) }
                guard let synthetic else { return true }
                // The ramp at full gain, drawn as the edit or as the original
                // (which keeps the source's own HDR).
                let content = CanvasComposition(original: original ? synthetic : nil, edited: synthetic,
                                                mode: original ? .original : .edited, headroom: 8)
                let drawn = try renderer.draw(in: layer, composition: content, transform: snapshot.transform)
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
        guard layer.drawableSize != snapshot.drawableSize else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.drawableSize = snapshot.drawableSize
        CATransaction.commit()
    }
}
