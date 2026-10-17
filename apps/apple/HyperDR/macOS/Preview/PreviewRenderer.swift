import CoreGraphics
import Foundation
import HyperDREngine
import Metal
import QuartzCore

/// The native float planes a frame hands to Metal. They are the frame's own
/// storage (no copy); tests build the same shape from Swift arrays.
struct FramePlanes {
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

    init(_ frame: PreviewFrame, device: any MTLDevice) throws {
        let planes = try frame.metalBuffers(device: device)
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
struct ReconstructParams {
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
        self.original = original ? 1 : 0
        gainMin = planes.gainMin
        gainMax = planes.gainMax
        inverseGamma = 1 / max(planes.gainGamma, 0.0001)
        gainWeight = planes.gainWeight
        baseOffset = planes.baseOffset
        alternateOffset = planes.alternateOffset
    }
}

/// Matches `DisplayParams` in Preview.metal.
struct DisplayParams {
    var rect: SIMD4<Float>
}

enum PreviewError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Two-pass renderer: reconstruct the frame into an `rgba16Float` intermediate
/// from the engine's native planes, then draw that intermediate through
/// `CanvasTransform` into the EDR drawable.
@MainActor
final class PreviewRenderer {
    let device: any MTLDevice
    let library: any MTLLibrary
    let queue: any MTLCommandQueue
    private let reconstructPipeline: any MTLComputePipelineState
    private let reconstruct32Pipeline: any MTLComputePipelineState
    private let displayPipeline: any MTLRenderPipelineState
    private struct Prepared {
        let identity: ObjectIdentifier
        let original: Bool
        let texture: any MTLTexture
        let planes: FramePlanes
    }
    private var prepared: Prepared?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PreviewError.unavailable("Metal 设备不可用")
        }
        self.device = device
        self.queue = queue
        library = try device.makeDefaultLibrary(bundle: Bundle(for: PreviewRenderer.self))
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
        let identity = ObjectIdentifier(frame)
        if let prepared, prepared.identity == identity, prepared.original == original {
            return prepared.texture
        }
        return try prepare(planes: FramePlanes(frame, device: device),
            original: original, identity: identity)
    }

    /// Same pass for buffers the caller owns (the diagnostic ramp and tests).
    @discardableResult
    func prepare(planes: FramePlanes, original: Bool) throws -> any MTLTexture {
        try prepare(planes: planes, original: original, identity: ObjectIdentifier(planes.base))
    }

    private func prepare(planes: FramePlanes, original: Bool,
                         identity: ObjectIdentifier) throws -> any MTLTexture {
        // The identity alone is not enough: an address can be reused by a new
        // frame once the old one is released.
        if let prepared, prepared.identity == identity, prepared.original == original,
           prepared.planes.width == planes.width, prepared.planes.height == planes.height {
            return prepared.texture
        }
        let texture = try Self.intermediateTexture(device: device,
            width: planes.width, height: planes.height)
        encodeReconstruct(planes, original: original, into: texture, pipeline: reconstructPipeline)
        prepared = Prepared(identity: identity, original: original, texture: texture,
                            planes: planes)
        return texture
    }

    /// The frame whose planes the intermediate currently owns, if any.
    var readyFrameIdentity: ObjectIdentifier? { prepared?.identity }

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

    func draw(in layer: CAMetalLayer, transform: CanvasTransform) {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let prepared, let drawable = layer.nextDrawable(),
              let command = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(displayPipeline)
            var params = DisplayParams(rect: Self.normalisedRect(transform,
                drawableSize: layer.drawableSize))
            encoder.setVertexBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            encoder.setFragmentTexture(prepared.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        command.present(drawable)
        command.commit()
    }

    /// Presents an empty (fully transparent) drawable, so closing a photo does
    /// not leave the previous frame on screen.
    func clear(in layer: CAMetalLayer) {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let command = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            encoder.endEncoding()
        }
        command.present(drawable)
        command.commit()
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
        var base = [Float](repeating: 0, count: width * height * 4)
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
                base[index + 3] = 1
                // 0…3 stops of gain reproduces the 0–8× ramp.
                gain[y * width + x] = value
            }
        }
        guard let baseBuffer = device.makeBuffer(bytes: base,
                  length: base.count * MemoryLayout<Float>.size, options: .storageModeShared),
              let gainBuffer = device.makeBuffer(bytes: gain,
                  length: gain.count * MemoryLayout<Float>.size, options: .storageModeShared) else {
            throw PreviewError.unavailable("无法分配 Metal 缓冲")
        }
        return FramePlanes(base: baseBuffer, baseRowBytes: width * 16,
                           gain: gainBuffer, gainRowBytes: width * 4,
                           gainChannels: 1, width: width, height: height,
                           gainWidth: width, gainHeight: height,
                           gainMin: 0, gainMax: 3, gainGamma: 1, gainWeight: 1)
    }

    private static func requireTexture(device: any MTLDevice,
                                       descriptor: MTLTextureDescriptor) throws -> any MTLTexture {
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreviewError.unavailable("无法分配 Metal 纹理")
        }
        return texture
    }
}
