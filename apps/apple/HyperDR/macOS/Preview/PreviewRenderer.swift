import CoreGraphics
import Foundation
import HyperDREngine
import Metal
import os
import QuartzCore
import Synchronization

/// Draws a `CanvasComposition` (Render's display pairs) into the EDR drawable
/// through the shared `DisplayCompositor`, behind the in-flight gate.
///
/// Not tied to an actor: a canvas confines its renderer to its own render
/// thread (`PreviewRenderLoop`); tests drive one from a single thread too. Only
/// the in-flight count is shared, and it is locked.
nonisolated final class PreviewRenderer: @unchecked Sendable {
    let device: any MTLDevice
    let library: any MTLLibrary
    let queue: any MTLCommandQueue
    private var compositor: DisplayCompositor?

    /// Intervals for A3's frame-time table: rebuilding the layers, waiting for
    /// a drawable, encoding, present + commit, and each presenting command
    /// buffer from commit to GPU completion. Busy ticks are events.
    static let signposter = DisplayCompositor.signposter
    /// One id per renderer: the main canvas and the frame sheet's canvas run
    /// at once, and their intervals must not pair with each other's.
    let signpostID = PreviewRenderer.signposter.makeSignpostID()
    /// Width and height of `syntheticRamp()`'s default pair.
    static let syntheticRampSize = CGSize(width: 512, height: 128)

    /// At most this many presenting command buffers may be uncompleted before
    /// `draw` / `clear` stop asking for drawables (A2b-1, the in-flight gate).
    static let maxInFlight = 1
    /// Presenting command buffers committed and not yet completed.
    var inFlight: Int { inFlightCount.withLock { $0 } }
    private let inFlightCount = Mutex(0)
    /// The most presentations ever in flight at once (tests).
    var maxInFlightObserved: Int { maxObserved.withLock { $0 } }
    private let maxObserved = Mutex(0)
    /// True while the GPU has not caught up: a draw now would wait in
    /// `nextDrawable`, so the caller should wait and retry.
    var isBusy: Bool { inFlight >= Self.maxInFlight }
    /// Test/owner callbacks can change while the render thread runs. Copy
    /// under the mutex and invoke after releasing it (callbacks may re-enter).
    private struct Hooks: Sendable {
        var completed: (@Sendable () -> Void)?
        var drawable: @Sendable (CAMetalLayer) -> (any CAMetalDrawable)? = { $0.nextDrawable() }
        var command: (@Sendable (any MTLCommandBuffer) -> Void)?
        var prepare: (@Sendable () throws -> Void)?
    }
    private let hooks = Mutex(Hooks())

    var onPresentationCompleted: (@Sendable () -> Void)? {
        get { hooks.withLock { $0.completed } }
        set { hooks.withLock { $0.completed = newValue } }
    }
    var drawableSource: @Sendable (CAMetalLayer) -> (any CAMetalDrawable)? {
        get { hooks.withLock { $0.drawable } }
        set { hooks.withLock { $0.drawable = newValue } }
    }
    var presentingCommandHook: (@Sendable (any MTLCommandBuffer) -> Void)? {
        get { hooks.withLock { $0.command } }
        set { hooks.withLock { $0.command = newValue } }
    }
    /// Injects a resource/preparation failure without submitting invalid GPU
    /// commands; used to verify the executor's error and retry boundary.
    var preparationHook: (@Sendable () throws -> Void)? {
        get { hooks.withLock { $0.prepare } }
        set { hooks.withLock { $0.prepare = newValue } }
    }

    init(library suppliedLibrary: (any MTLLibrary)? = nil) throws {
        guard let device = suppliedLibrary?.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PreviewError.unavailable("No Metal device")
        }
        self.device = device
        self.queue = queue
        library = try suppliedLibrary ?? device.makeDefaultLibrary(bundle: Bundle(for: PreviewRenderer.self))
    }

    /// Lets go of the display pairs the compositor holds.
    func releaseFrame() { compositor?.releasePairs() }

    /// The edited pair the compositor currently holds, if any (tests).
    var readyFrameIdentity: ObjectIdentifier? { compositor?.heldIdentity }

    // MARK: - Drawing

    /// True after a `draw` or `clear` that presented nothing because no
    /// drawable was available or the gate was closed: the caller must try
    /// again on the next display tick or the canvas stays stale until some
    /// unrelated change. Cleared by the next call that presents.
    private(set) var needsRetry = false

    /// Records a draw refused because `isBusy`. The render loop waits for
    /// completion instead of asking, so in the app this stays at zero.
    func noteBusyTick() {
        busyCount.withLock { $0 += 1 }
        Self.signposter.emitEvent("Busy", id: signpostID)
    }
    var busyRefusals: Int { busyCount.withLock { $0 } }
    private let busyCount = Mutex(0)

    /// Presents `composition`; false when nothing was presented and the call
    /// must be retried (`needsRetry` is set): a presenting command buffer is
    /// still in flight, or no drawable was available. An empty layer is not a
    /// failure. Every layer, overlay and detail goes in ONE command buffer.
    ///
    /// `nextDrawable` blocks the calling thread, up to one second by default;
    /// `allowsNextDrawableTimeout = false` would make that unbounded, so the
    /// bound is kept. The render loop asks only once the GPU has caught up.
    @discardableResult
    func draw(in layer: CAMetalLayer, composition: CanvasComposition, transform: CanvasTransform) throws -> Bool {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else {
            needsRetry = false   // nothing to present: not a miss
            return true
        }
        guard let drawable = acquireDrawable(layer) else { return false }
        try preparationHook?()
        guard let command = makePresentingCommand() else {
            needsRetry = true
            return false
        }
        if compositor == nil { compositor = try DisplayCompositor(device: device, library: library) }
        let interval = Self.signposter.beginInterval("Encode", id: signpostID)
        defer { Self.signposter.endInterval("Encode", interval) }
        try compositor?.encode(composition, transform: transform, target: drawable.texture, command: command)
        needsRetry = false
        submit(command, presenting: drawable)
        return true
    }

    /// Presents an empty (fully transparent) drawable, so closing a photo does
    /// not leave the previous frame on screen, and lets go of the intermediate
    /// and the frame it was built from.
    /// False when nothing was presented (see `draw`); the frame is let go of
    /// either way, and `needsRetry` is set so the clear is tried again.
    @discardableResult
    func clear(in layer: CAMetalLayer) -> Bool {
        releaseFrame()
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else {
            needsRetry = true    // no drawable was cleared at this size
            return false
        }
        guard let drawable = acquireDrawable(layer), let command = makePresentingCommand() else {
            needsRetry = true
            return false
        }
        needsRetry = false
        if let encoder = command.makeRenderCommandEncoder(descriptor: EDRDisplayPass.clearPass(drawable)) {
            encoder.endEncoding()
        }
        submit(command, presenting: drawable)
        return true
    }

    /// The gate, then the drawable. Sets `needsRetry` when either is missing;
    /// a closed gate never calls `nextDrawable`.
    private func acquireDrawable(_ layer: CAMetalLayer) -> (any CAMetalDrawable)? {
        guard !isBusy else {
            noteBusyTick()
            needsRetry = true
            return nil
        }
        let signpost = Self.signposter.beginInterval("NextDrawable", id: signpostID)
        let drawable = drawableSource(layer)
        Self.signposter.endInterval("NextDrawable", signpost)
        if drawable == nil { needsRetry = true }
        return drawable
    }

    private func makePresentingCommand() -> (any MTLCommandBuffer)? {
        guard let command = queue.makeCommandBuffer() else { return nil }
        presentingCommandHook?(command)
        return command
    }

    /// Presents and commits, counting the buffer in flight until the GPU
    /// completes it; the completion handler drops the count and then tells
    /// the owner (the render loop wakes and draws its newest snapshot).
    private func submit(_ command: any MTLCommandBuffer, presenting drawable: any CAMetalDrawable) {
        let presenting = Self.signposter.beginInterval("Present", id: signpostID)
        let gpu = Self.signposter.beginInterval("InFlight", id: signpostID)
        let count = inFlightCount.withLock { value in value += 1; return value }
        maxObserved.withLock { $0 = max($0, count) }
        let completed = onPresentationCompleted
        // Holds the renderer until the GPU is done with its textures.
        command.addCompletedHandler { [self] _ in
            Self.signposter.endInterval("InFlight", gpu)
            inFlightCount.withLock { $0 -= 1 }
            completed?()
        }
        command.present(drawable)
        command.commit()
        Self.signposter.endInterval("Present", presenting)
    }

    // MARK: - Textures

    /// Shared texture used by the diagnostic window and by tests.
    static func texture(device: any MTLDevice, width: Int, height: Int, values: [Float],
                        monochrome: Bool = false) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: monochrome ? .r32Float : .rgba32Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try EDRDisplayPass.makeTexture(device: device, descriptor: descriptor)
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * (monochrome ? 4 : 16))
        }
        return texture
    }

    /// The 0–8× ramp the diagnostic window shows in place of a photo: 0…3
    /// stops of log2 gain over an SDR ramp in three tints.
    static func syntheticRamp(device: any MTLDevice, width: Int = 512, height: Int = 128) throws -> DisplayPair {
        var base = [Float](repeating: 1, count: width * height * 4)
        var gain = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = Float(x) / Float(width - 1)
                let tint: SIMD3<Float> = y < height / 3
                    ? SIMD3(1, 0.65, 0.3)
                    : y < 2 * height / 3 ? SIMD3(repeating: 1) : SIMD3(0.2, 0.65, 1)
                let index = (y * width + x) * 4
                base[index] = min(1, tint.x * value)
                base[index + 1] = min(1, tint.y * value)
                base[index + 2] = min(1, tint.z * value)
                gain[y * width + x] = 3 * value
            }
        }
        return DisplayPair(base: try texture(device: device, width: width, height: height, values: base),
                           gain: try texture(device: device, width: width, height: height, values: gain, monochrome: true),
                           alternateHeadroom: 3)
    }
}
