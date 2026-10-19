import CoreGraphics
import Foundation
import HyperDREngine
import Metal
import os
import QuartzCore
import Synchronization

/// The native float planes a frame hands to Metal. They are the frame's own
/// storage (no copy); tests build the same shape from Swift arrays.
nonisolated struct FramePlanes: @unchecked Sendable {
    let base: any MTLBuffer
    let baseRowBytes: Int
    let gain: any MTLBuffer
    let gainRowBytes: Int
    let gainChannels: Int
    let width: Int
    let height: Int
    let gainWidth: Int
    let gainHeight: Int
    let gainMin: Float
    let gainMax: Float
    let gainGamma: Float
    let gainWeight: Float
    let baseOffset: Float
    let alternateOffset: Float

    init(base: any MTLBuffer, baseRowBytes: Int, gain: any MTLBuffer, gainRowBytes: Int,
         gainChannels: Int, width: Int, height: Int, gainWidth: Int, gainHeight: Int,
         gainMin: Float = 0, gainMax: Float = 0, gainGamma: Float = 1, gainWeight: Float = 1,
         baseOffset: Float = 0, alternateOffset: Float = 0) {
        self.base = base
        self.baseRowBytes = baseRowBytes
        self.gain = gain
        self.gainRowBytes = gainRowBytes
        self.gainChannels = gainChannels
        self.width = width
        self.height = height
        self.gainWidth = gainWidth
        self.gainHeight = gainHeight
        self.gainMin = gainMin
        self.gainMax = gainMax
        self.gainGamma = gainGamma
        self.gainWeight = gainWeight
        self.baseOffset = baseOffset
        self.alternateOffset = alternateOffset
    }

    init(_ frame: PreviewFrame, device: any MTLDevice, trace: PreviewTrace? = nil) throws {
        let planes = try frame.metalBuffers(device: device, trace: trace)
        let metadata = frame.metadata
        self.init(base: planes.base, baseRowBytes: frame.base.rowBytes,
                  gain: planes.gain, gainRowBytes: frame.gain.rowBytes,
                  gainChannels: frame.gain.channels,
                  width: frame.base.width, height: frame.base.height,
                  gainWidth: frame.gain.width, gainHeight: frame.gain.height,
                  gainMin: Float(metadata.gainMin ?? 0),
                  gainMax: Float(metadata.gainMax ?? 0),
                  gainGamma: Float(metadata.gainGamma ?? 1),
                  gainWeight: Float(metadata.gainWeight ?? 1),
                  baseOffset: Float(metadata.baseOffset ?? 0),
                  alternateOffset: Float(metadata.alternateOffset ?? 0))
    }
}

/// Matches `ReconstructParams` in Preview.metal: all members are 4 bytes and
/// the stride is asserted in `init` so a layout drift fails loudly.
nonisolated struct ReconstructParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var baseRowBytes: UInt32 = 0
    var gainWidth: UInt32 = 0
    var gainHeight: UInt32 = 0
    var gainRowBytes: UInt32 = 0
    var gainChannels: UInt32 = 0
    var original: UInt32 = 0
    var gainMin: Float = 0
    var gainMax: Float = 0
    var inverseGamma: Float = 1
    var gainWeight: Float = 1
    var baseOffset: Float = 0
    var alternateOffset: Float = 0

    init(planes: FramePlanes, original: Bool) {
        width = UInt32(planes.width)
        height = UInt32(planes.height)
        baseRowBytes = UInt32(planes.baseRowBytes)
        gainWidth = UInt32(planes.gainWidth)
        gainHeight = UInt32(planes.gainHeight)
        gainRowBytes = UInt32(planes.gainRowBytes)
        gainChannels = UInt32(planes.gainChannels)
        self.original = 0 // original photos reconstruct their OWN HDR gain
        gainMin = planes.gainMin
        gainMax = planes.gainMax
        inverseGamma = 1 / max(planes.gainGamma, 0.0001)
        gainWeight = planes.gainWeight
        baseOffset = planes.baseOffset
        alternateOffset = planes.alternateOffset
    }
}

/// Matches `DisplayParams` in Preview.metal.
nonisolated struct DisplayParams {
    var rect: SIMD4<Float>
}

/// A renderer failure. The message is a developer-facing English detail: the
/// model reports it as `metal_unavailable`, whose title and message come from
/// the catalogue, and `ErrorText` shows the detail untranslated.
nonisolated enum PreviewError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Two-pass renderer: reconstruct the frame into an `rgba16Float` intermediate
/// from the engine's native planes, then draw that intermediate through
/// `CanvasTransform` into the EDR drawable.
///
/// Not tied to an actor: a canvas confines its renderer to its own render
/// thread (`PreviewRenderLoop`); tests drive one from a single thread too. Only
/// the in-flight count is shared, and it is locked.
nonisolated final class PreviewRenderer: @unchecked Sendable {
    let device: any MTLDevice
    let library: any MTLLibrary
    let queue: any MTLCommandQueue
    private let reconstructPipeline: any MTLComputePipelineState
    private let reconstruct32Pipeline: any MTLComputePipelineState
    private let displayPipeline: any MTLRenderPipelineState
    /// The intermediate and what it was built from. `source` (the frame, or
    /// the caller's base buffer) is held, so its address cannot be reused by a
    /// newer object while the cache compares against it, and a frame's
    /// no-copy planes stay valid as long as they are referenced here.
    private struct Prepared {
        let source: AnyObject
        let original: Bool
        let texture: any MTLTexture
        let planes: FramePlanes
    }
    private var prepared: Prepared?
    private var compositor: CanvasCompositor?

    /// Intervals for A3's frame-time table: pass 1, waiting for a drawable,
    /// pass 2 encoding, present + commit, and each presenting command buffer
    /// from commit to GPU completion. Busy ticks are events.
    static let signposter = OSSignposter(subsystem: "com.hyperdr.HyperDR", category: "Canvas")
    /// One id per renderer: the main canvas and the frame sheet's canvas run
    /// at once, and their intervals must not pair with each other's.
    let signpostID = PreviewRenderer.signposter.makeSignpostID()
    /// Width and height of `syntheticRamp()`'s default planes.
    static let syntheticRampSize = CGSize(width: 512, height: 128)

    /// At most this many presenting command buffers may be uncompleted before
    /// `draw` / `clear` stop asking for drawables (A2b-1, the in-flight gate).
    static let maxInFlight = 1
    /// Presenting command buffers committed and not yet completed. Pass 1
    /// buffers are not counted: they share the queue, so a presenting buffer
    /// completes only after every pass 1 committed before it.
    var inFlight: Int { inFlightCount.withLock { $0 } }
    private let inFlightCount = Mutex(0)
    /// The most presentations ever in flight at once (tests).
    var maxInFlightObserved: Int { maxObserved.withLock { $0 } }
    private let maxObserved = Mutex(0)
    /// How many times pass 1 rebuilt the intermediate (tests).
    var pass1Runs: Int { pass1Count.withLock { $0 } }
    private let pass1Count = Mutex(0)
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
        reconstructPipeline = try Self.computePipeline(device: device, library: library,
            name: "reconstructFrame")
        reconstruct32Pipeline = try Self.computePipeline(device: device, library: library,
            name: "reconstructFrame32")
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "previewDisplayVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "previewDisplayFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        displayPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard MemoryLayout<ReconstructParams>.stride == 56,
              MemoryLayout<DisplayParams>.stride == 16 else {
            throw PreviewError.unavailable("Preview shader parameter layout changed")
        }
    }

    private static func computePipeline(device: any MTLDevice, library: any MTLLibrary,
                                        name: String) throws -> any MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw PreviewError.unavailable("Missing Metal function \(name)")
        }
        return try device.makeComputePipelineState(function: function)
    }

    // MARK: - Pass 1

    /// Rebuilds the intermediate only when the frame or the view mode changed.
    @discardableResult
    func prepare(frame: PreviewFrame, original: Bool) throws -> any MTLTexture {
        try preparationHook?()
        if let prepared, prepared.source === frame, prepared.original == original {
            return prepared.texture
        }
        return try prepare(planes: FramePlanes(frame, device: device),
            original: original, source: frame)
    }

    /// Same pass for buffers the caller owns (the diagnostic ramp and tests).
    @discardableResult
    func prepare(planes: FramePlanes, original: Bool) throws -> any MTLTexture {
        try preparationHook?()
        if let prepared, prepared.source === planes.base, prepared.original == original {
            return prepared.texture
        }
        return try prepare(planes: planes, original: original, source: planes.base)
    }

    private func prepare(planes: FramePlanes, original: Bool,
                         source: AnyObject) throws -> any MTLTexture {
        pass1Count.withLock { $0 += 1 }
        let signpost = Self.signposter.beginInterval("Pass1", id: signpostID)
        defer { Self.signposter.endInterval("Pass1", signpost) }
        let texture = try Self.intermediateTexture(device: device,
            width: planes.width, height: planes.height)
        encodeReconstruct(planes, original: original, into: texture, pipeline: reconstructPipeline)
        prepared = Prepared(source: source, original: original, texture: texture,
                            planes: planes)
        return texture
    }

    /// Whether the cached intermediate was built from `source` (a frame, or a
    /// caller's base buffer), which the cache then holds.
    func isPrepared(from source: AnyObject) -> Bool { prepared?.source === source }

    /// Lets go of the intermediate and the frame it was built from.
    func releaseFrame() { prepared = nil; compositor?.releaseFrames() }

    /// The frame or buffer whose planes the intermediate currently owns, if any.
    var readyFrameIdentity: ObjectIdentifier? { prepared.map { ObjectIdentifier($0.source) } }

    func encodeReconstruct(_ planes: FramePlanes, original: Bool, into texture: any MTLTexture,
                           pipeline: (any MTLComputePipelineState)? = nil) {
        var params = ReconstructParams(planes: planes, original: original)
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline ?? reconstructPipeline)
        encoder.setBuffer(planes.base, offset: 0, index: 0)
        encoder.setBuffer(planes.gain, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ReconstructParams>.stride, index: 2)
        encoder.setTexture(texture, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: planes.width, height: planes.height, depth: 1),
                                threadsPerThreadgroup: group)
        encoder.endEncoding()
        if texture.mipmapLevelCount > 1, let blit = command.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        command.commit()
    }

    /// Test hook: run pass 1 into a float-readable texture so the shader can be
    /// compared with the frozen Web reference without half-float rounding.
    func reconstructFloat(planes: FramePlanes) throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: planes.width, height: planes.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try Self.requireTexture(device: device, descriptor: descriptor)
        var params = ReconstructParams(planes: planes, original: false)
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw PreviewError.unavailable("Metal command buffer unavailable")
        }
        encoder.setComputePipelineState(reconstruct32Pipeline)
        encoder.setBuffer(planes.base, offset: 0, index: 0)
        encoder.setBuffer(planes.gain, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ReconstructParams>.stride, index: 2)
        encoder.setTexture(texture, index: 0)
        encoder.dispatchThreads(MTLSize(width: planes.width, height: planes.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var pixels = [Float](repeating: 0, count: planes.width * planes.height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: planes.width * 16,
                from: MTLRegionMake2D(0, 0, planes.width, planes.height), mipmapLevel: 0)
        }
        return pixels
    }

    /// Reads the production `rgba16Float` intermediate back as floats.
    func readIntermediate(frame: PreviewFrame, original: Bool) throws -> [Float] {
        let texture = try prepare(frame: frame, original: original)
        return try readHalfTexture(texture, width: frame.base.width, height: frame.base.height)
    }

    func readIntermediate(planes: FramePlanes, original: Bool) throws -> [Float] {
        let texture = try prepare(planes: planes, original: original)
        return try readHalfTexture(texture, width: planes.width, height: planes.height)
    }

    private func readHalfTexture(_ texture: any MTLTexture, width: Int, height: Int) throws
        -> [Float] {
        guard let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else {
            throw PreviewError.unavailable("Metal command buffer unavailable")
        }
        let bytesPerRow = width * 8
        guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            throw PreviewError.unavailable("Unable to allocate a readback buffer")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        let halves = buffer.contents().bindMemory(to: Float16.self, capacity: width * height * 4)
        return (0..<(width * height * 4)).map { Float(halves[$0]) }
    }

    // MARK: - Pass 2

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

    /// Presents the prepared frame; false when nothing was presented and the
    /// call must be retried (`needsRetry` is set): a presenting command buffer
    /// is still in flight, or no drawable was available (the layer's swap
    /// queue was exhausted or it is misconfigured). Nothing to draw (no frame,
    /// empty layer) is not a failure.
    ///
    /// `nextDrawable` blocks the calling thread, up to one second by default;
    /// `allowsNextDrawableTimeout = false` would make that unbounded, so the
    /// bound is kept. The gate means the main thread asks only once the GPU
    /// has caught up; a compositor holding drawables can still make it wait
    /// (A2b-2 moves the wait off the main thread).
    @discardableResult
    func draw(in layer: CAMetalLayer, transform: CanvasTransform) -> Bool {
        guard prepared != nil else {
            needsRetry = false   // nothing to present: not a miss
            return true
        }
        // A prepared frame needs no pass 1.
        return (try? draw(in: layer, transform: transform, preparing: {})) ?? false
    }

    /// The executor's draw: the gate, then the drawable, and only then pass 1
    /// (`prepare`), so a missing drawable never runs pass 1 (A2b-1 review
    /// P3-2). Pass 1 errors are thrown; nothing is presented then.
    @discardableResult
    func draw(in layer: CAMetalLayer, transform: CanvasTransform,
              preparing prepare: () throws -> Void) throws -> Bool {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else {
            needsRetry = false   // nothing to present: not a miss
            return true
        }
        guard let drawable = acquireDrawable(layer) else { return false }
        try prepare()
        guard let prepared else {
            needsRetry = false   // nothing to present: not a miss
            return true
        }
        guard let command = makePresentingCommand() else {
            needsRetry = true
            return false
        }
        needsRetry = false
        let encoding = Self.signposter.beginInterval("Encode", id: signpostID)
        let pass = Self.clearPass(drawable)
        if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(displayPipeline)
            var params = DisplayParams(rect: Self.normalisedRect(transform,
                drawableSize: layer.drawableSize))
            encoder.setVertexBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            encoder.setFragmentTexture(prepared.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        Self.signposter.endInterval("Encode", encoding)
        submit(command, presenting: drawable)
        return true
    }

    /// Composition obeys the same gate and submits ONE command buffer for
    /// both sides, every local layer and every overlay.
    func draw(in layer: CAMetalLayer, composition: CanvasComposition, transform: CanvasTransform) throws -> Bool {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return true }
        guard let drawable = acquireDrawable(layer), let command = makePresentingCommand() else { return false }
        if compositor == nil { compositor = try CanvasCompositor(device: device, queue: queue, library: library) }
        let interval = Self.signposter.beginInterval("Encode",id:signpostID)
        defer { Self.signposter.endInterval("Encode",interval) }
        try compositor?.encode(composition, transform: transform, target: drawable.texture, command: command)
        needsRetry = false
        submit(command, presenting: drawable, trace: composition.presentationTrace ?? (composition.mode == .original ? composition.original?.trace : composition.edited.trace))
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
        if let encoder = command.makeRenderCommandEncoder(descriptor: Self.clearPass(drawable)) {
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

    private static func clearPass(_ drawable: any CAMetalDrawable) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private func makePresentingCommand() -> (any MTLCommandBuffer)? {
        guard let command = queue.makeCommandBuffer() else { return nil }
        presentingCommandHook?(command)
        return command
    }

    /// Presents and commits, counting the buffer in flight until the GPU
    /// completes it; the completion handler drops the count and then tells
    /// the owner (the render loop wakes and draws its newest snapshot).
    private func submit(_ command: any MTLCommandBuffer, presenting drawable: any CAMetalDrawable, trace: PreviewTrace? = nil) {
        let timing = trace?.begin("commit_to_gpu_complete")
        if let trace { drawable.addPresentedHandler { drawable in trace.didPresent(at: drawable.presentedTime) } }
        let presenting = Self.signposter.beginInterval("Present", id: signpostID)
        let gpu = Self.signposter.beginInterval("InFlight", id: signpostID)
        let count = inFlightCount.withLock { value in value += 1; return value }
        maxObserved.withLock { $0 = max($0, count) }
        let completed = onPresentationCompleted
        // Holds the renderer until the GPU is done with its textures.
        command.addCompletedHandler { [self] completedCommand in
            if let timing { trace?.end("commit_to_gpu_complete", timing) }
            if completedCommand.status == .error { trace?.record("gpu", "failed") }
            Self.signposter.endInterval("InFlight", gpu)
            inFlightCount.withLock { $0 -= 1 }
            completed?()
        }
        command.present(drawable)
        command.commit()
        Self.signposter.endInterval("Present", presenting)
    }

    /// The photo rect in normalised device coordinates, y up. Edges snap to
    /// whole device pixels so a 100% view lands on the source grid instead of
    /// resampling by a fraction of a pixel.
    static func normalisedRect(_ transform: CanvasTransform,
                               drawableSize: CGSize) -> SIMD4<Float> {
        let frame = transform.imageFrame
        let width = max(drawableSize.width, 1)
        let height = max(drawableSize.height, 1)
        let scale = width / max(transform.viewport.width, 1)
        func pixel(_ points: CGFloat) -> Float {
            Float((points * scale).rounded())
        }
        let x0 = 2 * pixel(frame.minX) / Float(width) - 1
        let x1 = 2 * pixel(frame.maxX) / Float(width) - 1
        let bottom = 1 - 2 * pixel(frame.maxY) / Float(height)
        let top = 1 - 2 * pixel(frame.minY) / Float(height)
        return SIMD4<Float>(x0, bottom, x1, top)
    }

    // MARK: - Textures

    static func intermediateTexture(device: any MTLDevice, width: Int, height: Int) throws
        -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: max(width, 1), height: max(height, 1), mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let texture = try requireTexture(device: device, descriptor: descriptor)
        return texture
    }

    /// Shared texture used by the diagnostic window and by tests.
    static func texture(device: any MTLDevice, width: Int, height: Int, values: [Float],
                        monochrome: Bool = false) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: monochrome ? .r32Float : .rgba32Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try requireTexture(device: device, descriptor: descriptor)
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * (monochrome ? 4 : 16))
        }
        return texture
    }

    /// The 0–8× ramp the diagnostic window shows in place of a photo.
    static func syntheticRamp(device: any MTLDevice, width: Int = 512, height: Int = 128) throws
        -> FramePlanes {
        var base = [Float](repeating: 0, count: width * height * 3)
        var gain = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = Float(x) / Float(width - 1)
                let tint: SIMD3<Float> = y < height / 3
                    ? SIMD3(1, 0.65, 0.3)
                    : y < 2 * height / 3 ? SIMD3(repeating: 1) : SIMD3(0.2, 0.65, 1)
                let index = (y * width + x) * 3
                base[index] = min(1, tint.x * value)
                base[index + 1] = min(1, tint.y * value)
                base[index + 2] = min(1, tint.z * value)
                // 0…3 stops of gain reproduces the 0–8× ramp.
                gain[y * width + x] = value
            }
        }
        guard let baseBuffer = device.makeBuffer(bytes: base,
                  length: base.count * MemoryLayout<Float>.size, options: .storageModeShared),
              let gainBuffer = device.makeBuffer(bytes: gain,
                  length: gain.count * MemoryLayout<Float>.size, options: .storageModeShared) else {
            throw PreviewError.unavailable("Unable to allocate the synthetic ramp buffers")
        }
        return FramePlanes(base: baseBuffer, baseRowBytes: width * 12,
                           gain: gainBuffer, gainRowBytes: width * 4,
                           gainChannels: 1, width: width, height: height,
                           gainWidth: width, gainHeight: height,
                           gainMin: 0, gainMax: 3, gainGamma: 1, gainWeight: 1)
    }

    private static func requireTexture(device: any MTLDevice,
                                       descriptor: MTLTextureDescriptor) throws -> any MTLTexture {
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreviewError.unavailable("Unable to allocate a Metal texture")
        }
        return texture
    }
}
