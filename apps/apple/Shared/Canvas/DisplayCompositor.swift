import HyperDRRender
import CoreGraphics
import HyperDRDesign
import Metal
import os
import simd

/// Immutable state captured by the main actor; the compositor owns all GPU
/// resources it derives from it. Detail pairs carry their `region`.
nonisolated struct DisplayComposition: @unchecked Sendable {
    enum Mode: Sendable { case original, edited, compare }
    /// Needed when shown, and whenever `originalDetail` is set: that
    /// detail's weight follows it.
    var original: DisplayPair?
    var edited: DisplayPair
    var originalDetail: DisplayPair?
    var editedDetail: DisplayPair?
    var mode: Mode = .edited
    var splitRatio = 0.5
    /// The screen's linear headroom.
    var headroom = 1.0
    var overlays = CanvasOverlays()
    var previewsAsSDR = false
    /// The publication each layer's rebuild is timed for.
    var originalTrace: (any CanvasTrace)? = nil
    var editedTrace: (any CanvasTrace)? = nil
    var originalDetailTrace: (any CanvasTrace)? = nil
    var editedDetailTrace: (any CanvasTrace)? = nil
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
    var padding0: Float = 0
    var hdrRange: Float = 0
    var backingScale: Float = 1
    var padding1: Float = 0
    var padding2: Float = 0
    var padding: Float = 0
    var maskColor = SIMD4(CanvasOverlayStyle.mask, CanvasOverlayStyle.maskOpacity)
    var highlightColor = SIMD4(CanvasOverlayStyle.highlight, CanvasOverlayStyle.zebraOpacity)
    var shadowColor = SIMD4(CanvasOverlayStyle.shadow, CanvasOverlayStyle.zebraOpacity)
    var stripe = SIMD4<Float>(CanvasOverlayStyle.stripePeriodPoints, CanvasOverlayStyle.stripeWidthPoints, CanvasOverlayStyle.stripeDirection.x, CanvasOverlayStyle.stripeDirection.y)
}

/// Matches `DisplayLayerParams` in Composition.metal.
nonisolated struct DisplayLayerParams {
    var baseOffset: SIMD4<Float>
    var alternateOffset: SIMD4<Float>
    var p3ToGain: simd_float3x3
    var gainToP3: simd_float3x3
    var weight: Float = 1
    var gainChannelCount: UInt32 = 1
    var coding: UInt32 = 0 // 0 log2, 1 alternate rendition
    var firstSlice: UInt32 = 0
    var firstPlane: UInt32 = 0
    var identity: UInt32 = 1

    init(_ pair: DisplayPair, weight: Float, slice: UInt32, weightedOnly: Bool) {
        baseOffset = SIMD4(pair.baseOffset, 0)
        alternateOffset = SIMD4(pair.alternateOffset, 0)
        p3ToGain = pair.p3ToGain; gainToP3 = pair.gainToP3
        identity = pair.p3ToGain == matrix_identity_float3x3 && pair.gainToP3 == matrix_identity_float3x3 ? 1 : 0
        coding = pair.coding == .alternate ? 1 : 0
        self.weight = min(1, max(0, weight))
        gainChannelCount = UInt32(pair.gainChannelCount)
        firstSlice = slice
        firstPlane = weightedOnly ? 2 : 0
    }
}

/// Each cache has base, full HDR for statistics, and weighted linear HDR.
/// Weight changes rebuild the latter before spatial/mip filtering, from the
/// pair's own gain; no information is recovered from clipped pixels.
/// Two whole-image caches and ONE local texture array (edited + original in
/// separate slices). The array avoids retaining two independent local GPU
/// allocations while keeping both sides equally sharp in comparison mode.
///
/// Display tone mapping to the screen's headroom lives here, in the display
/// layer; export never goes through it (gpu-pipeline §11).
nonisolated final class DisplayCompositor {
    static let signposter = OSSignposter(subsystem: "com.hyperdr.HyperDR", category: "Canvas")
    private let device: any MTLDevice
    private let compose: any MTLComputePipelineState
    private let display: any MTLRenderPipelineState
    private struct Entry {
        let pair: DisplayPair
        let texture: any MTLTexture
        var weight: Float
    }
    private var original: Entry?
    private var edited: Entry?
    private var detailOriginal: DisplayPair?
    private var detailEdited: DisplayPair?
    private var detailTexture: (any MTLTexture)?
    private var detailOriginalWeight: Float?
    private var detailEditedWeight: Float?
    private(set) var rebuilds = 0
    private(set) var textureAllocations = 0
    private let signpostID = DisplayCompositor.signposter.makeSignpostID()

    init(device: any MTLDevice, library: any MTLLibrary) throws {
        self.device = device
        guard let compute = library.makeFunction(name: "composeDisplayLayers") else {
            throw PreviewError.unavailable("Missing composition compute shader")
        }
        compose = try device.makeComputePipelineState(function: compute)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "compositionVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "compositionFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        display = try device.makeRenderPipelineState(descriptor: descriptor)
        guard MemoryLayout<CompositionParams>.stride == 128, MemoryLayout<DisplayLayerParams>.stride == 160 else {
            throw PreviewError.unavailable("Composition parameter layout changed")
        }
    }

    /// The edited base the compositor holds, if any (tests).
    var heldIdentity: ObjectIdentifier? { edited.map { ObjectIdentifier($0.pair.base) } }

    func releasePairs() {
        original = nil; edited = nil
        detailOriginal = nil; detailEdited = nil; detailTexture = nil
        detailOriginalWeight = nil; detailEditedWeight = nil
    }

    private func texture(width: Int, height: Int, slices: Int, mipmapped: Bool = false) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: mipmapped)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = slices
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        let limit = RenderEngine.maximumTextureDimension(device:device)
        guard descriptor.width > 0, descriptor.height > 0, descriptor.width <= limit, descriptor.height <= limit else {
            throw PreviewError.unavailable("Composition dimensions exceed this device's texture limit")
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreviewError.unavailable("Unable to allocate composition texture")
        }
        textureAllocations += 1
        return texture
    }

    /// Writes base, full HDR and weighted HDR into three slices from `slice`
    /// (only the weighted one when `weightedOnly`). Synthetic pixel tests use
    /// exactly this pass.
    func encode(_ pair: DisplayPair, into texture: any MTLTexture, slice: UInt32,
                weight: Float, weightedOnly: Bool = false, command: any MTLCommandBuffer,
                trace: (any CanvasTrace)? = nil) throws {
        let timing = trace?.begin("pass1_encode")
        defer { if let timing { trace?.end("pass1_encode", timing) } }
        let interval = Self.signposter.beginInterval("Pass1", id: signpostID)
        defer { Self.signposter.endInterval("Pass1", interval) }
        guard let encoder = trace?.makeLayerEncoder(device: device, command: command)
                ?? command.makeComputeCommandEncoder() else {
            throw PreviewError.unavailable("Unable to create composition compute encoder")
        }
        var params = DisplayLayerParams(pair, weight: weight, slice: slice, weightedOnly: weightedOnly)
        encoder.setComputePipelineState(compose)
        encoder.setTexture(pair.base, index: 0)
        encoder.setTexture(pair.gain, index: 1)
        encoder.setTexture(texture, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<DisplayLayerParams>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: pair.width, height: pair.height, depth: weightedOnly ? 1 : 3),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        if texture.mipmapLevelCount > 1 {
            // A view shares storage. Updating headroom allocates no new GPU
            // memory and does not regenerate base/full-HDR mip chains.
            let mipTarget: any MTLTexture
            if weightedOnly {
                guard let view = texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D,
                    levels: 0..<texture.mipmapLevelCount,
                    slices: (Int(slice)+2)..<(Int(slice)+3)) else {
                    throw PreviewError.unavailable("Unable to view weighted composition mipmaps")
                }
                mipTarget = view
            } else { mipTarget = texture }
            guard let blit = command.makeBlitCommandEncoder() else {
                throw PreviewError.unavailable("Unable to create composition mipmap encoder")
            }
            blit.generateMipmaps(for: mipTarget)
            blit.endEncoding()
        }
        rebuilds += 1
    }

    private static func same(_ a: DisplayPair?, _ b: DisplayPair?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.hasSameContent(as: b)
    }

    private func prepare(_ pair: DisplayPair, weight: Float, previous: Entry?, command: any MTLCommandBuffer,
                         trace: (any CanvasTrace)?) throws -> Entry {
        if var previous, Self.same(previous.pair, pair) {
            if DisplayWeight.needsRebuild(from: previous.weight, to: weight) {
                try encode(pair, into: previous.texture, slice: 0, weight: weight, weightedOnly: true, command: command, trace: trace)
                previous.weight = weight
            }
            return previous
        }
        let result = try texture(width: pair.width, height: pair.height, slices: 3, mipmapped: true)
        try encode(pair, into: result, slice: 0, weight: weight, command: command, trace: trace)
        return Entry(pair: pair, texture: result, weight: weight)
    }

    /// All preparation and the complete display pass share the ONE presenting
    /// command buffer supplied by the caller's in-flight gate. On failure that
    /// buffer is never committed, so nothing it would have written is kept.
    func encode(_ content: DisplayComposition, transform: CanvasTransform, target: any MTLTexture,
                command: any MTLCommandBuffer) throws {
        do { try encodeComposition(content, transform: transform, target: target, command: command) }
        catch { releasePairs(); throw error }
    }

    private func encodeComposition(_ content: DisplayComposition, transform: CanvasTransform, target: any MTLTexture,
                                   command: any MTLCommandBuffer) throws {
        edited = try prepare(content.edited, weight: content.edited.weight(headroom: content.headroom),
                             previous: edited, command: command, trace: content.editedTrace)
        if let pair = content.original, content.mode != .edited {
            original = try prepare(pair, weight: pair.weight(headroom: content.headroom),
                                   previous: original, command: command, trace: content.originalTrace)
        }
        let wantOriginal = content.originalDetail
        let wantEdited = content.editedDetail
        // A crop can report a different local peak. Its display weight must
        // follow its WHOLE rendition, or the tile gains a brightness seam.
        let originalWeight = wantOriginal.map { (content.original ?? $0).weight(headroom: content.headroom) }
        let editedWeight = wantEdited.map { _ in content.edited.weight(headroom: content.headroom) }
        if !Self.same(detailOriginal, wantOriginal) || !Self.same(detailEdited, wantEdited) {
            let width = max(wantOriginal?.width ?? 0, wantEdited?.width ?? 0)
            let height = max(wantOriginal?.height ?? 0, wantEdited?.height ?? 0)
            var atlas: (any MTLTexture)?
            if width > 0, height > 0 {
                let texture = try texture(width: width, height: height, slices: 6)
                if let pair = wantOriginal, let weight = originalWeight { try encode(pair, into: texture, slice: 0, weight: weight, command: command, trace: content.originalDetailTrace) }
                if let pair = wantEdited, let weight = editedWeight { try encode(pair, into: texture, slice: 3, weight: weight, command: command, trace: content.editedDetailTrace) }
                atlas = texture
            }
            detailOriginal = wantOriginal; detailEdited = wantEdited; detailTexture = atlas
            detailOriginalWeight = originalWeight; detailEditedWeight = editedWeight
        } else if let atlas = detailTexture {
            if let pair = wantOriginal, let weight = originalWeight, DisplayWeight.needsRebuild(from: detailOriginalWeight, to: weight) {
                try encode(pair, into: atlas, slice: 0, weight: weight, weightedOnly: true, command: command, trace: content.originalDetailTrace)
                detailOriginalWeight = weight
            }
            if let pair = wantEdited, let weight = editedWeight, DisplayWeight.needsRebuild(from: detailEditedWeight, to: weight) {
                try encode(pair, into: atlas, slice: 3, weight: weight, weightedOnly: true, command: command, trace: content.editedDetailTrace)
                detailEditedWeight = weight
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
            var params = parameters(content, original: isOriginal, transform: transform)
            params.rect = EDRDisplayPass.normalisedRect(transform, drawableSize: size)
            draw(encoder, texture: entry.texture, params: params)
            if let atlas = detailTexture, let pair = isOriginal ? detailOriginal : detailEdited,
               let region = pair.region {
                let normalized = CGRect(x: region.minX / transform.imageSize.width,
                    y: region.minY / transform.imageSize.height,
                    width: region.width / transform.imageSize.width, height: region.height / transform.imageSize.height)
                params.rect = Self.tileRect(normalized, transform: transform)
                params.uvScale = SIMD2(Float(pair.width) / Float(atlas.width), Float(pair.height) / Float(atlas.height))
                params.slice = isOriginal ? 0 : 3
                draw(encoder, texture: atlas, params: params)
            }
        }
        if content.mode != .edited, let original { side(original, original: true) }
        if content.mode != .original, let edited { side(edited, original: false) }
        encoder.endEncoding()
    }

    /// A part of the photo (fractions of the whole) in clip space. Converted
    /// directly rather than through `normalisedRect`, so a tile stays in the
    /// whole photo's transform and clip.
    private static func tileRect(_ normalized: CGRect, transform: CanvasTransform) -> SIMD4<Float> {
        let image = transform.imageFrame
        let tile = CGRect(x: image.minX + normalized.minX * image.width,
            y: image.minY + normalized.minY * image.height,
            width: normalized.width * image.width, height: normalized.height * image.height)
        return SIMD4(Float(tile.minX / transform.viewport.width * 2 - 1),
            Float(1 - tile.maxY / transform.viewport.height * 2),
            Float(tile.maxX / transform.viewport.width * 2 - 1), Float(1 - tile.minY / transform.viewport.height * 2))
    }

    private func parameters(_ content: DisplayComposition, original: Bool,
                            transform: CanvasTransform) -> CompositionParams {
        var params = CompositionParams(rect: .zero)
        params.backingScale = Float(max(1, transform.backingScale))
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

    func makeTestTexture(_ pair: DisplayPair, weight: Float = 1, mipmapped: Bool = false,
                         command: any MTLCommandBuffer) throws -> any MTLTexture {
        let result = try texture(width: pair.width, height: pair.height, slices: 3, mipmapped: mipmapped)
        try encode(pair, into: result, slice: 0, weight: weight, command: command)
        return result
    }
}
