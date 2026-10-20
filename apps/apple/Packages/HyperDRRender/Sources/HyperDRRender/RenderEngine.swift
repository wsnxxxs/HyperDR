import Foundation
import CoreImage
import Metal
import HyperDRRecipe

/// One serialized GPU service per editor/export context, independent of UI frameworks.
/// Task cancellation is checked before/after decode and each GPU stripe; already
/// submitted GPU work is allowed to finish, and its cancelled result is discarded.
public actor RenderEngine {
    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    public let device: any MTLDevice
    let queue: any MTLCommandQueue
    let context: CIContext
    let library: any MTLLibrary
    let pipelines: [String: any MTLComputePipelineState]
    var analysisCache: (key: AnalysisKey, result: SpatialAnalysis)?
    var lutCache: (id: UUID, texture: any MTLTexture, buffer: any MTLBuffer)?
    var authorCache: (id: UUID, base: any MTLTexture, hdr: any MTLTexture, metadata: ISOLogGainMetadata)?
    private var sourceCache: (key: SourceKey, source: RenderSource)?
    private var hdrCache: (id: UUID, texture: any MTLTexture)?
    private var outputCache: (key: OutputKey, planes: RenderPlanes)?

    func releaseNodeOutput() { outputCache = nil }

    private struct SourceKey: Equatable {
        let url: URL
        let size: Int?
        let modified: Date?
        let options: SourceOptions
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
        let shader = try String(contentsOf: url, encoding: .utf8) + "\n" + String(contentsOf: adjustmentURL, encoding: .utf8)
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: shader, options: options)
        self.library = library
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in ["sourceHDRSplit", "sampleSource", "zeroGain", "adjustPoint", "graphCells", "graphBox",
                     "graphWeights", "graphCoefficients", "graphFinalGain", "graphOutput", "graphPeak", "authoredOutput"] {
            guard let function = library.makeFunction(name: name) else { throw RenderError.gpu(name) }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
    }

    public func clearCaches() {
        sourceCache = nil
        hdrCache = nil
        outputCache = nil
        analysisCache = nil
        lutCache = nil
        authorCache = nil
        context.clearCaches()
    }

    /// The caller owns any security scope needed to read this URL. No UI-thread I/O.
    public func load(_ url: URL, options: SourceOptions = SourceOptions()) throws -> RenderSource {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = SourceKey(url: url.standardizedFileURL, size: values.fileSize,
                            modified: values.contentModificationDate, options: options)
        if let cached = sourceCache, cached.key == key { return cached.source }
        // Bound internal source residency to one image, including its RAW development.
        clearCaches()
        let opened = try Self.open(url, options: options)
        let source = try materialize(opened)
        sourceCache = (key, source)
        return source
    }

    /// Synthetic/test and already-decoded source boundary. CI coordinates are
    /// bottom-left; this method normalizes extent, row order, and working space.
    public func source(image: CIImage, domain: InputDomain) throws -> RenderSource {
        guard domain != .dual else { throw RenderError.missingGainMap }
        return try materialize(OpenedSource(domain: domain, image: image, hdr: image,
                                             baseSpace: Self.workingColorSpace, gain: nil, raw: nil))
    }

    private func materialize(_ opened: OpenedSource) throws -> RenderSource {
        let texture = try rasterize(opened.image, space: opened.baseSpace)
        let gainTexture = try opened.gain.map { try rasterize($0.image, space: nil,
                                                    format: $0.channelCount == 1 ? .r32Float : .rgba32Float) }
        return RenderSource(id: UUID(), domain: opened.domain,
            size: PixelSize(width: texture.width, height: texture.height), authoredGainMap: opened.gain,
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

    /// Preview and export share this graph. An unchanged dual source retains its
    /// authored pair; other HDR sources are automatically split at the output.
    public func render(_ source: RenderSource, size: PixelSize? = nil,
                       nodes: [any RenderNode] = []) throws -> RenderPlanes {
        try Task.checkCancellation()
        let size = size ?? source.size
        try validate(size)
        let key = OutputKey(source: source.id, size: size, nodes: nodes.map(\.cacheKey))
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

    private struct Sampling { var width, height, x, y: UInt32 }

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
            if let cached = hdrCache, cached.id == source.id { texture = cached.texture } else {
                texture = try rasterize(source.hdrImage, space: Self.workingColorSpace)
                hdrCache = (source.id, texture)
            }
        }
        guard let buffer = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let context = nodeContext(domain: source.domain, buffer: buffer)
        let wholeSource = size == source.size && inputRegion == bounds
        func sample(_ texture: any MTLTexture, preserveNativeSize: Bool = false) throws -> any MTLTexture {
            if wholeSource && ((preserveNativeSize && region == bounds) ||
                               (texture.width == size.width && texture.height == size.height)) { return texture }
            let target = try context.texture(width: Int(inputRegion.width), height: Int(inputRegion.height), format: texture.pixelFormat)
            var sampling = Sampling(width: UInt32(size.width), height: UInt32(size.height),
                                    x: UInt32(inputRegion.minX), y: UInt32(inputRegion.minY))
            try context.dispatch("sampleSource", width: target.width, height: target.height,
                                 textures: [texture, target], value: &sampling)
            return target
        }
        let base = try sample(texture)
        let gain: any MTLTexture
        if authored, let nativeGain = source.gainTexture { gain = try sample(nativeGain, preserveNativeSize: true) } else {
            gain = try context.texture(width: base.width, height: base.height, format: .r32Float)
            var unused: UInt32 = 0
            try context.dispatch("zeroGain", width: gain.width, height: gain.height, textures: [gain], value: &unused)
        }
        var planes = RenderPlanes(base: base, gain: gain,
            gainChannelCount: authored ? source.authoredGainMap!.channelCount : 1,
            encoding: authored ? .authored(source.authoredGainMap!) : .log2,
            baseColorSpace: authored ? source.baseSpace : Self.workingColorSpace,
            provenance: authored ? .authored : .identity, region: inputRegion)
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
                encoding: planes.encoding, baseColorSpace: planes.baseColorSpace, provenance: planes.provenance, region: region)
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
        if let cached = hdrCache, cached.id == source.id { return RenderedTexture(texture: cached.texture, colorSpace: Self.workingColorSpace) }
        let texture = try rasterize(source.hdrImage, space: Self.workingColorSpace)
        hdrCache = (source.id, texture)
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
