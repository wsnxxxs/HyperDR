import CoreGraphics
import HyperDREngine
import HyperDRDesign
import Metal

/// Immutable state captured by the main actor. The executor owns all GPU
/// resources; photo pixel storage stays alive through these frame references.
nonisolated struct CanvasComposition: @unchecked Sendable {
    enum Mode: Sendable { case original, edited, compare }
    var original: PreviewFrame?
    var edited: PreviewFrame
    var originalDetail: PreviewFrame?
    var editedDetail: PreviewFrame?
    var mode: Mode = .edited
    var splitRatio = 0.5
    var headroom = 1.0
    var overlays = CanvasOverlays()
    var previewsAsSDR = false
}

nonisolated struct CanvasOverlays: Equatable, Sendable {
    var highlights = false
    var shadows = false
    var mask = false
    var hdrRange: Float = 0
}

/// CPU and Metal ABI; every vector starts on its natural alignment boundary.
nonisolated struct CompositionParams {
    var rect: SIMD4<Float>
    /// Atlas UV multiplier for a detail layer smaller than the shared atlas.
    var uvScale = SIMD2<Float>(repeating: 1)
    var slice: UInt32 = 0
    var flags: UInt32 = 0 // bit 0 SDR, 1 highlight, 2 shadow, 3 mask
    var weight: Float = 1
    var hdrRange: Float = 0
    var backingScale: Float = 1
    var baseOffset: Float = 0
    var alternateOffset: Float = 0
    var padding: Float = 0
    var maskColor = SIMD4(CanvasOverlayStyle.mask, CanvasOverlayStyle.maskOpacity)
    var highlightColor = SIMD4(CanvasOverlayStyle.highlight, CanvasOverlayStyle.zebraOpacity)
    var shadowColor = SIMD4(CanvasOverlayStyle.shadow, CanvasOverlayStyle.zebraOpacity)
    var stripe = SIMD4<Float>(CanvasOverlayStyle.stripePeriodPoints, CanvasOverlayStyle.stripeWidthPoints, CanvasOverlayStyle.stripeDirection.x, CanvasOverlayStyle.stripeDirection.y)
}

/// Two whole-image caches and ONE local texture array (edited + original in
/// separate slices). The array avoids retaining two independent local GPU
/// allocations while keeping both sides equally sharp in comparison mode.
nonisolated final class CanvasCompositor {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let reconstruct: any MTLComputePipelineState
    private let display: any MTLRenderPipelineState
    private struct Entry {
        let source: PreviewFrame
        let texture: any MTLTexture
    }
    private var original: Entry?
    private var edited: Entry?
    private var detailOriginal: PreviewFrame?
    private var detailEdited: PreviewFrame?
    private var detailTexture: (any MTLTexture)?
    private(set) var rebuilds = 0
    private let signpostID = PreviewRenderer.signposter.makeSignpostID()

    init(device: any MTLDevice, queue: any MTLCommandQueue, library: any MTLLibrary) throws {
        self.device = device; self.queue = queue
        guard let compute = library.makeFunction(name: "reconstructComposition") else {
            throw PreviewError.unavailable("Missing composition compute shader")
        }
        reconstruct = try device.makeComputePipelineState(function: compute)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "compositionVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "compositionFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        display = try device.makeRenderPipelineState(descriptor: descriptor)
        guard MemoryLayout<CompositionParams>.stride == 128 else {
            throw PreviewError.unavailable("Composition parameter layout changed")
        }
    }

    func releaseFrames() {
        original = nil; edited = nil
        detailOriginal = nil; detailEdited = nil; detailTexture = nil
    }

    private func texture(width: Int, height: Int, slices: Int, mipmapped: Bool = false) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: mipmapped)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = slices
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreviewError.unavailable("Unable to allocate composition texture")
        }
        return texture
    }

    private func encode(_ frame: PreviewFrame, into texture: any MTLTexture, slice: UInt32,
                        command: any MTLCommandBuffer) throws {
        let planes = try FramePlanes(frame, device: device)
        try encode(planes, into: texture, slice: slice, command: command)
    }

    /// Also used by synthetic, offscreen pixel tests: exactly the production
    /// compute and display passes, with no independent test implementation.
    func encode(_ planes: FramePlanes, into texture: any MTLTexture, slice: UInt32,
                command: any MTLCommandBuffer) throws {
        let interval = PreviewRenderer.signposter.beginInterval("Pass1",id:signpostID)
        defer { PreviewRenderer.signposter.endInterval("Pass1",interval) }
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw PreviewError.unavailable("Unable to create composition compute encoder")
        }
        var params = ReconstructParams(planes: planes, original: false)
        params.gainWeight = 1
        var startSlice = slice
        encoder.setComputePipelineState(reconstruct)
        encoder.setBuffer(planes.base, offset: 0, index: 0)
        encoder.setBuffer(planes.gain, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ReconstructParams>.stride, index: 2)
        encoder.setBytes(&startSlice, length: 4, index: 3)
        encoder.setTexture(texture, index: 0)
        encoder.dispatchThreads(MTLSize(width: planes.width, height: planes.height, depth: 2),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        if texture.mipmapLevelCount > 1, let blit = command.makeBlitCommandEncoder() {
            blit.generateMipmaps(for:texture)
            blit.endEncoding()
        }
        rebuilds += 1
    }

    private func prepare(_ frame: PreviewFrame, previous: Entry?, command: any MTLCommandBuffer) throws -> Entry {
        if let previous, previous.source === frame { return previous }
        let result = try texture(width: frame.base.width, height: frame.base.height, slices: 2, mipmapped: true)
        try encode(frame, into: result, slice: 0, command: command)
        return Entry(source: frame, texture: result)
    }

    /// All preparation and the complete display pass share the ONE presenting
    /// command buffer supplied by PreviewRenderer's in-flight gate.
    func encode(_ content: CanvasComposition, transform: CanvasTransform, target: any MTLTexture,
                command: any MTLCommandBuffer) throws {
        edited = try prepare(content.edited, previous: edited, command: command)
        if let frame = content.original, content.mode != .edited {
            original = try prepare(frame, previous: original, command: command)
        }
        let wantOriginal = content.originalDetail
        let wantEdited = content.editedDetail
        if detailOriginal !== wantOriginal || detailEdited !== wantEdited {
            detailOriginal = wantOriginal; detailEdited = wantEdited; detailTexture = nil
            let width = max(wantOriginal?.base.width ?? 0, wantEdited?.base.width ?? 0)
            let height = max(wantOriginal?.base.height ?? 0, wantEdited?.base.height ?? 0)
            if width > 0, height > 0 {
                let atlas = try texture(width: width, height: height, slices: 4)
                if let wantOriginal { try encode(wantOriginal, into: atlas, slice: 0, command: command) }
                if let wantEdited { try encode(wantEdited, into: atlas, slice: 2, command: command) }
                detailTexture = atlas
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw PreviewError.unavailable("Unable to create composition display encoder")
        }
        let size = CGSize(width: target.width, height: target.height)
        let rect = transform.imageFrame
        let ratio = min(0.95, max(0.05, content.splitRatio))
        let split = Int(((rect.minX + rect.width * ratio) * CGFloat(target.width) / transform.viewport.width).rounded())
        func side(_ entry: Entry, original isOriginal: Bool) {
            let lower = content.mode == .compare && !isOriginal ? max(0, min(target.width, split)) : 0
            let upper = content.mode == .compare && isOriginal ? max(0, min(target.width, split)) : target.width
            guard upper > lower else { return }
            encoder.setScissorRect(MTLScissorRect(x: lower, y: 0, width: upper - lower, height: target.height))
            var params = parameters(content, frame: entry.source, original: isOriginal, transform: transform)
            params.rect = PreviewRenderer.normalisedRect(transform, drawableSize: size)
            draw(encoder, texture: entry.texture, params: params)
            if let atlas = detailTexture, let frame = isOriginal ? detailOriginal : detailEdited,
               let region = Self.region(frame) {
                let normalized = CGRect(x: region.minX / transform.imageSize.width,
                    y: region.minY / transform.imageSize.height,
                    width: region.width / transform.imageSize.width, height: region.height / transform.imageSize.height)
                let image = transform.imageFrame
                let tile = CGRect(x: image.minX + normalized.minX * image.width,
                    y: image.minY + normalized.minY * image.height,
                    width: normalized.width * image.width, height: normalized.height * image.height)
                // normalisedRect uses imageFrame; direct conversion keeps the
                // local tile in the whole photo's transform and clip.
                params.rect = SIMD4(Float(tile.minX / transform.viewport.width * 2 - 1),
                    Float(1 - tile.maxY / transform.viewport.height * 2),
                    Float(tile.maxX / transform.viewport.width * 2 - 1), Float(1 - tile.minY / transform.viewport.height * 2))
                params.uvScale = SIMD2(Float(frame.base.width) / Float(atlas.width), Float(frame.base.height) / Float(atlas.height))
                params.slice = isOriginal ? 0 : 2
                draw(encoder, texture: atlas, params: params)
            }
        }
        if content.mode != .edited, let original { side(original, original: true) }
        if content.mode != .original, let edited { side(edited, original: false) }
        encoder.endEncoding()
    }

    static func region(_ frame: PreviewFrame) -> CGRect? {
        let m = frame.metadata
        guard m.detail == true, let x = m.regionX, let y = m.regionY else { return nil }
        return CGRect(x: x, y: y, width: m.width, height: m.height)
    }

    private func parameters(_ content: CanvasComposition, frame: PreviewFrame, original: Bool,
                            transform: CanvasTransform) -> CompositionParams {
        let m = frame.metadata
        let base = m.baseHeadroom ?? 0
        let alternate = m.alternateHeadroom ?? m.headroomStops
        let weight = alternate > base ? min(1, max(0, (log2(max(1, content.headroom)) - base) / (alternate - base))) : 1
        var params = CompositionParams(rect: .zero)
        params.weight = Float(weight)
        params.backingScale = Float(max(1, transform.backingScale))
        params.baseOffset = Float(m.baseOffset ?? 0)
        params.alternateOffset = Float(m.alternateOffset ?? 0)
        params.hdrRange = content.overlays.hdrRange
        params.flags = content.previewsAsSDR ? 1 : 0
        if !original {
            if content.overlays.highlights { params.flags |= 2 }
            if content.overlays.shadows { params.flags |= 4 }
            if content.overlays.mask { params.flags |= 8 }
        }
        return params
    }

    func draw(_ encoder: any MTLRenderCommandEncoder, texture: any MTLTexture, params: CompositionParams) {
        var params = params
        params.stripe.x *= params.backingScale
        params.stripe.y *= params.backingScale
        encoder.setRenderPipelineState(display)
        encoder.setVertexBytes(&params, length: MemoryLayout<CompositionParams>.stride, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<CompositionParams>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    func makeTestTexture(_ planes: FramePlanes, command: any MTLCommandBuffer) throws -> any MTLTexture {
        let result = try texture(width: planes.width, height: planes.height, slices: 2)
        try encode(planes, into: result, slice: 0, command: command)
        return result
    }
}
