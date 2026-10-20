import Foundation
import CryptoKit
import CoreImage
import Metal
import simd
import HyperDRRecipe

/// One serialized GPU service per editor/export context, independent of UI frameworks.
/// Task cancellation is checked before/after decode and each GPU stripe; already
/// submitted GPU work is allowed to finish, and its cancelled result is discarded.
public actor RenderEngine {
    // Explicit executor also permits a prepared export's synchronous entry to
    // enter the same isolation domain without waiting for an async actor hop.
    nonisolated let serialExecutor = ExportRowsExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { serialExecutor.asUnownedSerialExecutor() }

    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    public let device: any MTLDevice
    let queue: any MTLCommandQueue
    let context: CIContext
    let library: any MTLLibrary
    let pipelines: [String: any MTLComputePipelineState]
    var modelPredictionCache: [ModelPredictionKey:ModelGainPrediction] = [:]
    var modelPredictionOrder: [ModelPredictionKey] = []
    var modelFilterCache: (key: ModelFilterKey, gain: any MTLTexture, peak: Float)?
    var displayMatrices: [(space: CGColorSpace, matrix: simd_float3x3)] = []
    var analysisCache: (key: AnalysisKey, result: SpatialAnalysis)?
    var lutCache: (id: String, texture: any MTLTexture, buffer: any MTLBuffer)?
    var authorCache: (id: UUID, base: any MTLTexture, hdr: any MTLTexture, metadata: ISOLogGainMetadata)?
    private var sourceCache: [SourceKey: RenderSource] = [:]
    private var sourceFamily: (key: SourceKey, id: UUID)?
    var analysisSource: RenderSource?
    private var hdrCache: (id: UUID, texture: any MTLTexture)?
    private var outputCache: (key: OutputKey, planes: RenderPlanes)?

    func releaseNodeOutput() { outputCache = nil }

    private struct SourceKey: Hashable {
        let url: URL
        let revision: SourceRevision
        var options: SourceOptions
        var stableID: UUID {
            // Values are already in engine units; normalize signed zero and omit
            // preview size. Swift Hasher is intentionally randomized, so use SHA256.
            func number(_ value: Float?) -> String {
                value.map { String(($0 == 0 ? Float(0) : $0).bitPattern,radix:16) } ?? "source"
            }
            let r = options.raw
            let fields = ["hyperdr.source/v1",url.path,String(revision.size ?? -1),
                revision.modified.map { String($0.timeIntervalSinceReferenceDate.bitPattern,radix:16) } ?? "unknown",
                options.kind.rawValue,String(options.lensCorrection),number(r.temperature),number(r.tint),
                number(r.luminanceNR),number(r.colorNR),number(r.sharpness)]
            let data = try! JSONSerialization.data(withJSONObject:fields)
            var bytes = Array(SHA256.hash(data:data).prefix(16))
            bytes[6] = (bytes[6] & 15) | 0x80; bytes[8] = (bytes[8] & 63) | 0x80
            return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                              bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        }
    }
    private struct OutputKey: Equatable {
        let source: UUID
        let size: PixelSize
        let nodes: [String]
    }

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RenderError.metalUnavailable }
        self.device = device
        self.queue = queue
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: Self.workingColorSpace, .workingFormat: CIFormat.RGBAf.rawValue,
            .cacheIntermediates: false
        ])
        let url = Bundle.module.url(forResource: "Pipeline", withExtension: "metal", subdirectory: "Shaders")!
        let adjustmentURL = Bundle.module.url(forResource: "Adjustments", withExtension: "metal", subdirectory: "Shaders")!
        let displayURL = Bundle.module.url(forResource: "Display", withExtension: "metal", subdirectory: "Shaders")!
        let exportURL = Bundle.module.url(forResource:"Export",withExtension:"metal",subdirectory:"Shaders")!
        let shader = try String(contentsOf: url, encoding: .utf8) + "\n" + String(contentsOf: adjustmentURL, encoding: .utf8)
            + "\n" + String(contentsOf:displayURL,encoding:.utf8) + "\n" + String(contentsOf:exportURL,encoding:.utf8)
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: shader, options: options)
        self.library = library
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in ["sourceHDRSplit", "sampleSource", "zeroGain", "adjustPoint", "graphCells", "graphBox",
                     "graphWeights", "graphCoefficients", "graphFinalGain", "graphOutput", "graphPeak", "authoredOutput",
                     "displayBase", "displayISOGain", "displayGainPeak", "displayLegacyGain", "modelGainWeights", "effectMask", "exportSummary", "exportPair", "exportFrame"] {
            guard let function = library.makeFunction(name: name) else { throw RenderError.gpu(name) }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
    }

    public func clearCaches() {
        modelPredictionCache.removeAll()
        modelPredictionOrder.removeAll()
        clearImageCaches()
    }

    func clearImageCaches() {
        sourceCache.removeAll()
        analysisSource = nil
        modelFilterCache = nil
        hdrCache = nil
        outputCache = nil
        analysisCache = nil
        lutCache = nil
        authorCache = nil
        displayMatrices.removeAll()
        context.clearCaches()
    }

    /// The caller owns any security scope needed to read this URL. No UI-thread I/O.
    public func load(_ url: URL, options: SourceOptions = SourceOptions()) throws -> RenderSource {
        try Task.checkCancellation()
        let revision = try SourceRevision(url:url)
        let key = SourceKey(url:url.standardizedFileURL,revision:revision,options:options)
        if let cached = sourceCache[key] { return cached }
        var familyKey = key
        familyKey.options.resolution = .full
        if sourceFamily?.key != familyKey {
            clearImageCaches()
            sourceFamily = (familyKey,familyKey.stableID)
        }
        let opened = try Self.open(url, options: options)
        let source = try materialize(opened,id:sourceFamily!.id,origin:(familyKey.url,familyKey.options,revision))
        try revision.validate(url)
        // Retain full and the latest preview together, while bounding variant residency.
        sourceCache = sourceCache.filter { ($0.key.options.resolution == .full) != (options.resolution == .full) }
        sourceCache[key] = source
        return source
    }

    /// Stable analysis development for this asset/settings family, independent of
    /// which canvas tier or full-size variant the caller most recently loaded.
    func fixedAnalysisSource(_ source: RenderSource) throws -> RenderSource {
        guard let origin = source.origin else { return source }
        if let cached = analysisSource, cached.id == source.id { return cached }
        try origin.revision.validate(origin.url)
        var options = origin.options
        let scale = min(1,1024/Double(max(source.nativeSize.width,source.nativeSize.height)))
        options.resolution = .preview(maximumSize:PixelSize(width:max(1,Int((Double(source.nativeSize.width)*scale).rounded(.up))),
                                                          height:max(1,Int((Double(source.nativeSize.height)*scale).rounded(.up)))))
        let result = try materialize(Self.open(origin.url,options:options),id:source.id,origin:origin)
        try origin.revision.validate(origin.url)
        analysisSource = result
        return result
    }

    /// Synthetic/test and already-decoded source boundary. CI coordinates are
    /// bottom-left; this method normalizes extent, row order, and working space.
    public func source(image: CIImage, domain: InputDomain) throws -> RenderSource {
        guard domain != .dual else { throw RenderError.missingGainMap }
        return try materialize(OpenedSource(domain: domain, image: image, hdr: image,
                                             baseSpace: Self.workingColorSpace, gain: nil, raw: nil))
    }

    private func materialize(_ opened: OpenedSource, id: UUID = UUID(),
                             origin: (url: URL, options: SourceOptions, revision: SourceRevision)? = nil) throws -> RenderSource {
        let texture = try rasterize(opened.image, space: opened.baseSpace)
        // Retain the native encoded gain. Display decodes gamma before resampling.
        let gainTexture = try opened.gain.map { try rasterize($0.image, space: nil,
                                                    format: $0.channelCount == 1 ? .r32Float : .rgba32Float) }
        return RenderSource(id: id, renderID:UUID(), origin:origin, domain: opened.domain,
            size: PixelSize(width: texture.width, height: texture.height),
            nativeSize: opened.nativeSize ?? opened.raw?.nativeSize ?? PixelSize(width:texture.width,height:texture.height), authoredGainMap: opened.gain,
            hdrImage: opened.hdr, authoredBaseImage: opened.gain == nil ? nil : opened.image,
            rawSettings: opened.raw, texture: texture, baseSpace: opened.baseSpace, gainTexture: gainTexture)
    }

    func nodeContext(domain: InputDomain, buffer: any MTLCommandBuffer) -> RenderNodeContext {
        RenderNodeContext(domain: domain, device: device, commandBuffer: buffer,
                          workingSpace: Self.workingColorSpace, library: library, pipelines: pipelines)
    }

    func rasterize(_ image: CIImage, space: CGColorSpace?, format: MTLPixelFormat = .rgba32Float) throws -> any MTLTexture {
        try Task.checkCancellation()
        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0,
              extent.width <= Double(UInt32.max), extent.height <= Double(UInt32.max) else {
            throw RenderError.invalidSize
        }
        try validate(PixelSize(width: Int(extent.width), height: Int(extent.height)))
        guard let buffer = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let texture = try nodeContext(domain: .sdr, buffer: buffer).texture(
            width: Int(extent.width), height: Int(extent.height), format: format)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        // Core Image's y=0 row is the bottom of an image. The public texture and
        // readback contract is top-down, so perform exactly one vertical flip.
        let topDown = normalized.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height))
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: buffer)
        destination.colorSpace = space
        destination.isFlipped = false
        destination.alphaMode = .unpremultiplied
        _ = try context.startTask(toRender: topDown, to: destination)
        try finish(buffer)
        return texture
    }

    func finish(_ buffer: any MTLCommandBuffer) throws {
        buffer.commit()
        buffer.waitUntilCompleted()
        try Task.checkCancellation()
        guard buffer.status == .completed else { throw RenderError.gpu(buffer.error?.localizedDescription ?? "GPU command failed") }
    }

    func validate(_ size: PixelSize) throws {
        guard size.width > 0, size.height > 0,
              size.width <= Int(UInt32.max), size.height <= Int(UInt32.max) else { throw RenderError.invalidSize }
    }

    private func validate(_ nodes: [any RenderNode]) throws {
        guard nodes.filter({ $0 is SourceHDRSplitNode }).count <= 1 else { throw RenderError.duplicateHDRSplit }
    }

    /// Preview and export share this graph. An unchanged dual source retains its
    /// authored pair; other HDR sources are automatically split at the output.
    public func render(_ source: RenderSource, size: PixelSize? = nil,
                       nodes: [any RenderNode] = []) throws -> RenderPlanes {
        try Task.checkCancellation()
        try validate(nodes)
        let size = size ?? source.size
        try validate(size)
        let key = OutputKey(source: source.renderID, size: size, nodes: nodes.map(\.cacheKey))
        if let cached = outputCache, cached.key == key { return cached.planes }
        outputCache = nil
        let planes = try renderRegion(source, size: size,
            region: CGRect(x: 0, y: 0, width: size.width, height: size.height), nodes: nodes)
        outputCache = (key, planes)
        return planes
    }

    /// Calls consume once per completed stripe, then releases intermediate outputs.
    /// Source caches remain resident. Consumers must avoid retaining every stripe
    /// if they require bounded memory. Throwing from consume stops submission.
    public func renderStripes(_ source: RenderSource, size: PixelSize? = nil, rows: Int = 256,
                              nodes: [any RenderNode] = [],
                              consume: @Sendable (RenderPlanes) throws -> Void) throws {
        try Task.checkCancellation()
        try validate(nodes)
        let size = size ?? source.size
        try validate(size)
        guard rows > 0 else { throw RenderError.invalidSize }
        outputCache = nil
        for y in stride(from: 0, to: size.height, by: rows) {
            try Task.checkCancellation()
            try autoreleasepool {
                let output = try renderRegion(source, size: size,
                    region: CGRect(x: 0, y: y, width: size.width, height: min(rows, size.height - y)), nodes: nodes)
                try consume(output)
                try Task.checkCancellation()
            }
        }
    }


    func renderRegion(_ source: RenderSource, size: PixelSize, region: CGRect,
                              nodes: [any RenderNode]) throws -> RenderPlanes {
        let edited = nodes.contains { !$0.isIdentity }
        let authored = source.domain == .dual && !edited
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var inputRegion = region
        for node in nodes.reversed() {
            inputRegion = node.inputRegion(for: inputRegion, imageSize: size).integral.intersection(bounds)
        }
        guard !inputRegion.isNull, inputRegion.contains(region) else { throw RenderError.invalidRegion }
        var texture = source.texture
        if source.domain == .dual && edited {
            if let cached = hdrCache, cached.id == source.renderID { texture = cached.texture } else {
                texture = try rasterize(source.hdrImage, space: Self.workingColorSpace)
                hdrCache = (source.renderID, texture)
            }
        }
        guard let buffer = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let context = nodeContext(domain: source.domain, buffer: buffer)
        let wholeSource = size == source.size && inputRegion == bounds
        func sample(_ texture: any MTLTexture, samplingRegion: CGRect, preserveNativeSize: Bool = false) throws -> any MTLTexture {
            if samplingRegion == CGRect(x:0,y:0,width:1,height:1) && wholeSource && ((preserveNativeSize && region == bounds) ||
                               (texture.width == size.width && texture.height == size.height)) { return texture }
            let target = try context.texture(width: Int(inputRegion.width), height: Int(inputRegion.height), format: texture.pixelFormat)
            var sampling = SourceSampling(width: UInt32(size.width), height: UInt32(size.height),
                                    x: UInt32(inputRegion.minX), y: UInt32(inputRegion.minY), sourceRegion:sourceSampling(texture,samplingRegion))
            try context.dispatch("sampleSource", width: target.width, height: target.height,
                                 textures: [texture, target], value: &sampling)
            return target
        }
        let base = try sample(texture,samplingRegion:source.samplingRegion)
        let gain: any MTLTexture
        if authored, let nativeGain = source.gainTexture { gain = try sample(nativeGain,samplingRegion:source.gainSamplingRegion,preserveNativeSize:true) } else {
            gain = try context.texture(width: base.width, height: base.height, format: .r32Float)
            var unused: UInt32 = 0
            try context.dispatch("zeroGain", width: gain.width, height: gain.height, textures: [gain], value: &unused)
        }
        var planes = RenderPlanes(base: base, gain: gain,
            gainChannelCount: authored ? source.authoredGainMap!.channelCount : 1,
            encoding: authored ? .authored(source.authoredGainMap!) : .log2,
            baseColorSpace: authored ? source.baseSpace : Self.workingColorSpace,
            provenance: authored ? .authored : .identity, region: inputRegion, outputSize:size)
        for node in nodes {
            try Task.checkCancellation()
            planes = try node.encode(planes, context: context)
        }
        if !authored && source.domain != .sdr && planes.provenance == .identity {
            planes = try SourceHDRSplitNode().encode(planes, context: context)
        }
        if inputRegion != region {
            let croppedBase = try crop(planes.base, from: inputRegion, to: region, context: context)
            let croppedGain = try crop(planes.gain, from: inputRegion, to: region, context: context)
            planes = RenderPlanes(base: croppedBase, gain: croppedGain, gainChannelCount: planes.gainChannelCount,
                encoding: planes.encoding, baseColorSpace: planes.baseColorSpace, provenance: planes.provenance, region: region, outputSize:size, aiPending:planes.aiPending)
        }
        try finish(buffer)
        return planes
    }

    private func crop(_ texture: any MTLTexture, from: CGRect, to: CGRect,
                      context: RenderNodeContext) throws -> any MTLTexture {
        let result = try context.texture(width: Int(to.width), height: Int(to.height), format: texture.pixelFormat)
        guard let encoder = context.commandBuffer.makeBlitCommandEncoder() else { throw RenderError.allocationFailed }
        encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: Int(to.minX - from.minX), y: Int(to.minY - from.minY), z: 0),
            sourceSize: MTLSize(width: result.width, height: result.height, depth: 1),
            to: result, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()
        return result
    }

    /// System reconstruction of an imported pair, before editing. No luma-ratio
    /// approximation or custom interpretation of legacy Apple metadata is used.
    public func reconstructedHDR(_ source: RenderSource) throws -> RenderedTexture {
        try Task.checkCancellation()
        if source.domain != .dual { return RenderedTexture(texture: source.texture, colorSpace: Self.workingColorSpace) }
        if let cached = hdrCache, cached.id == source.renderID { return RenderedTexture(texture: cached.texture, colorSpace: Self.workingColorSpace) }
        let texture = try rasterize(source.hdrImage, space: Self.workingColorSpace)
        hdrCache = (source.renderID, texture)
        return RenderedTexture(texture: texture, colorSpace: Self.workingColorSpace)
    }

    public nonisolated static func readPixels(_ planes: RenderPlanes) -> PlanePixels {
        let base = readTexture(planes.base)
        let nativeGain = readTexture(planes.gain)
        let storageChannels = planes.gain.pixelFormat == .r32Float ? 1 : 4
        var gain: [Float] = []
        gain.reserveCapacity(planes.gain.width * planes.gain.height * planes.gainChannelCount)
        for index in 0..<(planes.gain.width * planes.gain.height) {
            for channel in 0..<planes.gainChannelCount { gain.append(nativeGain[index * storageChannels + channel]) }
        }
        return PlanePixels(size: PixelSize(width: planes.base.width, height: planes.base.height),
                           baseRGBA: base, gainSize: PixelSize(width: planes.gain.width, height: planes.gain.height),
                           gain: gain, gainChannelCount: planes.gainChannelCount)
    }

    public nonisolated static func readTexture(_ texture: any MTLTexture) -> [Float] {
        let components = texture.pixelFormat == .r32Float ? 1 : 4
        var result = [Float](repeating: 0, count: texture.width * texture.height * components)
        result.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * components * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }
}
