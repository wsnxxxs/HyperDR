import Foundation
import CoreGraphics
import Metal
import simd
import HyperDRRecipe

struct GraphUniform {
    var tone0, tone1, color, hdr: SIMD4<Float>
    var flags, lutInfo: SIMD4<UInt32>
    var lutMin, lutMax: SIMD4<Float>
    var region, mode: SIMD4<UInt32>
    var inputRegion: SIMD4<Float>
    var film: SIMD4<Float> = .zero
    var halation: SIMD4<Float> = .zero
    var scatter: SIMD4<Int32> = .zero
    var pair: SIMD4<Float> = .zero
    var effects: SIMD4<Float> = .zero
}
struct FilmBlurUniform { var radius, vertical, accumulate, unused: Int32 }
struct BoxUniform { var radius, vertical, width, height: UInt32 }
struct AuthorUniform {
    var minimum, maximum, inverseGamma, baseOffset, alternateOffset, controls: SIMD4<Float>
    var info: SIMD4<UInt32>
    var inputRegion,gainRegion: SIMD4<Float>
}
struct AnalysisKey: Equatable {
    let source: UUID
    let tone: ToneAdjustments
    let color: ColorAdjustments
    let look: LookAdjustments
    let film: FilmAdjustments
    let halation: Float
    let stockProcessing: Bool
    let start, coverage: Float
}

/// Analysis has one fixed longest edge (768), independent of preview/export size.
/// Mask channels are highlights, shadows, blacks, expansion participation.
public struct SpatialAnalysis: @unchecked Sendable {
    public let size: PixelSize
    public let cells: any MTLTexture
    public let masks: any MTLTexture
    /// Analytic gain in stops at a reference capacity of three stops.
    public let expansion: any MTLTexture
    /// Actual HDR peak, SDR-base peak, captured gain peak, analytic gain peak.
    public let peaks: SIMD4<Float>
    /// Original source capacity in stops, including authored headroom metadata.
    public let sourceHeadroom: Float
    /// Halation glow on the cells: film exposure for a stock, scene highlights otherwise.
    /// Its blur allows for the cells' and the render's B-spline sampling width.
    public var filmHalation: (any MTLTexture)? = nil
}

extension RenderEngine {
    func editedPairOffset(_ source: RenderSource) -> Float {
        // Preserve the common equal-offset ISO curve, including its intermediate
        // display weights. A tiny floor can encode a newly lit black channel.
        if let channels = source.authoredGainMap?.isoChannels, let first = channels.first,
           channels.allSatisfy({ $0.baseOffset == first.baseOffset && $0.alternateOffset == first.baseOffset }) {
            return max(1e-6, Float(first.baseOffset))
        }
        return 1 / 64
    }

    func workingInput(_ source: RenderSource) throws -> any MTLTexture {
        if source.domain == .dual { return try reconstructedHDR(source).texture }
        return source.texture
    }

    func lookupResources(_ lut: ColorLUT?) throws -> (texture: any MTLTexture, buffer: any MTLBuffer) {
        let id = lut?.id ?? ""
        if let cache = lutCache, cache.id == id { return (cache.texture, cache.buffer) }
        lutCache = nil
        let edge = lut?.is3D == true ? lut!.size : 2
        guard edge > 0, edge <= 2048 else { throw RenderError.invalidSize }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D; descriptor.pixelFormat = .rgba32Float
        descriptor.width = edge; descriptor.height = edge; descriptor.depth = edge
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocationFailed }
        let values = lut?.values.map { SIMD4($0, 1) } ?? [SIMD4<Float>(repeating: 0)]
        if lut?.is3D == true {
            values.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake3D(0, 0, 0, edge, edge, edge), mipmapLevel: 0,
                                slice: 0, withBytes: bytes.baseAddress!, bytesPerRow: edge * 16, bytesPerImage: edge * edge * 16)
            }
        }
        let bufferValues = lut?.is3D == false ? values : [SIMD4<Float>(repeating: 0)]
        let buffer = try bufferValues.withUnsafeBytes { bytes in
            guard let value = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                else { throw RenderError.allocationFailed }
            return value
        }
        lutCache = (id, texture, buffer)
        return (texture, buffer)
    }

    /// Strength, grain amount, 1/pixel area (µm⁻²) for a render of `size`, and the exposure factor.
    func filmUniform(_ source: RenderSource, _ film: FilmAdjustments, grain: Float, active: Bool, size: PixelSize) -> SIMD4<Float> {
        guard active, let stock = film.stock, let data = try? FilmStock.named(stock) else { return .zero }
        let inverseArea = FilmStock.inverseArea(longEdge: max(size.width, size.height), film: data.resource.filming)
        let exposure = film.exposure ?? ((try? filmMeter(source)) ?? 0)
        return SIMD4(film.strength, grain, Float(inverseArea), exp2(exposure))
    }

    /// The film's automatic exposure in stops: spektrafilm's centre-weighted meter
    /// (Gaussian, sigma 0.2 of the long edge) of the original photo's luminance, put
    /// at 18.4 %. Measured on the fixed analysis source, so preview and export agree,
    /// and before any edit, so the light edits still move the exposure.
    public func filmMeter(_ source: RenderSource) throws -> Float {
        let fixed = try fixedAnalysisSource(source)
        if let cache = filmMeterCache, cache.id == fixed.id { return cache.ev }
        let input = try workingInput(fixed)
        guard let command = queue.makeCommandBuffer(),
              let rows = device.makeBuffer(length: input.height * 8, options: .storageModeShared) else { throw RenderError.allocationFailed }
        let context = nodeContext(domain: fixed.domain, buffer: command)
        var unused: UInt32 = 0
        try context.dispatch("filmMeter", width: input.height, height: 1, textures: [input], buffers: [rows], value: &unused)
        try finish(command)
        let sums = UnsafeBufferPointer(start: rows.contents().bindMemory(to: SIMD2<Float>.self, capacity: input.height), count: input.height)
        let total = sums.reduce(SIMD2<Double>.zero) { $0 + SIMD2(Double($1.x), Double($1.y)) }
        let range = Adjustments.declaration("look.filmExposure")!.range!
        let ev = total.x > 0 && total.y > 0 ? min(max(-log2(total.x / total.y / 0.184), range.lowerBound), range.upperBound) : 0
        filmMeterCache = (fixed.id, Float(ev))
        return Float(ev)
    }

    /// The stock's tables and spectral upsampling texture; one texel and row when no film is active.
    func filmResources(_ film: FilmAdjustments, active: Bool = true, genericGrain: Bool = false) throws -> (texture: any MTLTexture, buffer: any MTLBuffer) {
        let stock = active ? film.stock : (genericGrain ? .portra400 : nil)
        if let cache = filmCache, cache.id == stock { return (cache.texture, cache.buffer) }
        filmCache = nil
        let texture: any MTLTexture, rows: [SIMD4<Float>]
        if let stock {
            let data = try FilmStock.named(stock)
            texture = try data.spectralTexture(device); rows = data.packed()
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
            descriptor.usage = .shaderRead; descriptor.storageMode = .shared
            guard let empty = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocationFailed }
            texture = empty; rows = [SIMD4<Float>(repeating: 0)]
        }
        let buffer = try rows.withUnsafeBytes { bytes in
            guard let value = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                else { throw RenderError.allocationFailed }
            return value
        }
        filmCache = (stock, texture, buffer)
        return (texture, buffer)
    }

    func graphUniform(_ source: RenderSource, _ edit: RenderAdjustments, size: PixelSize,
                      region: CGRect, range: Float = 3, shoulder: Bool = false) -> GraphUniform {
        let t = edit.tone, c = edit.color, h = edit.hdr, l = edit.look
        let lut = l.isIdentity ? nil : l.lut
        let domain: UInt32 = source.domain == .sdr ? 0 : source.domain == .hdr ? 1 : source.domain == .rawEDR ? 2 : 3
        let genericGrain = edit.film.stock == nil && edit.effects.grain > 0
        let referenceArea = genericGrain ? (try? FilmStock.named(.portra400)).map {
            Float(FilmStock.inverseArea(longEdge: max(size.width, size.height), film: $0.resource.filming))
        } ?? 0 : 0
        return GraphUniform(tone0: SIMD4(t.exposure, t.contrast, t.highlights, t.shadows),
            tone1: SIMD4(t.blacks, c.warmth, c.tint, c.vibrance), color: SIMD4(c.saturation, lut == nil ? 0 : l.strength, range, h.strength),
            hdr: SIMD4(h.expansionStart ?? RenderParameter.expansionStart, h.coverage, h.sdrRolloff, shoulder ? 1 : 0),
            flags: SIMD4(domain, lut != nil && l.input.isSDR ? 1 : 0,
                         lut != nil && !l.input.isSDR ? 1 : 0, h.enabled ? 1 : 0),
            lutInfo: SIMD4(UInt32(lut?.size ?? 2), lut?.is3D == false ? 0 : 1, l.input.rawValue, l.output.rawValue),
            lutMin: SIMD4(lut?.domainMinimum ?? .zero, 0), lutMax: SIMD4(lut?.domainMaximum ?? SIMD3(repeating: 1), 0),
            region: SIMD4(UInt32(size.width), UInt32(size.height), UInt32(region.minX), UInt32(region.minY)), mode: .zero,inputRegion:sourceSampling(source.texture,source.samplingRegion),
            film: filmUniform(source, edit.film, grain: edit.effects.grain, active: edit.usesFilmProcessing, size: size),
            pair: SIMD4(source.domain == .dual ? editedPairOffset(source)
                        : (!edit.effects.isIdentity && (edit.film.stock == nil || edit.film.strength < 1) ? 1 / 64 : 0), 0, 0, 0),
            effects: SIMD4(edit.film.stock == nil ? edit.effects.grain : 0,
                           edit.film.stock == nil ? edit.effects.halation : 0,
                           referenceArea, edit.usesFilmProcessing ? 1 : 0))
    }

    /// Fixed-scale statistics and masks are shared by preview and export. Changing
    /// strength, range, enabled or rolloff does not invalidate upstream analysis.
    public func analysis(_ source: RenderSource, adjustments edit: RenderAdjustments = RenderAdjustments()) throws -> SpatialAnalysis {
        try Task.checkCancellation()
        try edit.validate(domain:source.domain)
        let source = try fixedAnalysisSource(source)
        let key = AnalysisKey(source: source.id, tone: edit.tone, color: edit.color, look: edit.look, film: edit.film, halation: edit.effects.halation, stockProcessing: edit.usesFilmProcessing,
                              start: edit.hdr.expansionStart ?? RenderParameter.expansionStart, coverage: edit.hdr.coverage)
        if let cached = analysisCache, cached.key == key { return cached.result }
        analysisCache = nil
        let input = try workingInput(source)
        let ratio = min(1.0, 768.0 / Double(max(source.size.width, source.size.height)))
        let width = max(1, Int((Double(source.size.width) * ratio).rounded()))
        let height = max(1, Int((Double(source.size.height) * ratio).rounded()))
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let context = nodeContext(domain: source.domain, buffer: command)
        func texture(_ format: MTLPixelFormat = .rgba32Float) throws -> any MTLTexture {
            try context.texture(width: width, height: height, format: format)
        }
        let cells = try texture(), peaks = try texture(), masks = try texture()
        let env = try texture(), temp = try texture(), weights = try texture(), means = try texture()
        let coefficients = try texture(), smoothed = try texture(), expansion = try texture(.r32Float)
        let resources = try lookupResources(edit.look.isIdentity ? nil : edit.look.lut)
        let film = try filmResources(edit.film, active: edit.usesFilmProcessing)
        var parameters = graphUniform(source, edit, size: source.size,
            region: CGRect(x: 0, y: 0, width: source.size.width, height: source.size.height))
        parameters.film.y = 0 // grain averages out in the cells
        parameters.effects.x = 0
        // Analysis excludes generic endpoint effects and their encoding floor.
        // Turning grain on must not change the cached content statistics.
        if source.domain != .dual { parameters.pair.x = 0 }
        try context.dispatch("graphCells", width: width, height: height,
            textures: [input, cells, peaks, resources.texture, masks, film.texture, try lookBaseline(source, edit: edit)], buffers: [resources.buffer, film.buffer], value: &parameters)
        var halation: (any MTLTexture)? = nil
        if let stock = edit.film.stock, edit.usesFilmProcessing, edit.effects.halation > 0,
           let data = try? FilmStock.named(stock), data.halationStrength(edit.film, amount: edit.effects.halation).max() > 0 {
            let filmRaw = try texture(), glow = try texture()
            try context.dispatch("graphFilmCells", width: width, height: height,
                textures: [input, filmRaw, resources.texture, film.texture], buffers: [resources.buffer, film.buffer], value: &parameters)
            try filmBlur(filmRaw, into: glow, components: data.halationMapComponents(cells: max(width, height)),
                         truncate: FilmStock.halationTruncate, context: context)
            halation = glow
        }
        if edit.film.stock == nil && edit.effects.halation > 0 {
            let raw = try texture(), glow = try texture()
            try context.dispatch("graphEffectCells", width: width, height: height,
                textures: [input, raw, resources.texture], buffers: [resources.buffer], value: &parameters)
            let reference = try FilmStock.named(.portra400)
            try filmBlur(raw, into: glow, components: reference.halationMapComponents(cells: max(width, height)),
                         truncate: FilmStock.halationTruncate, context: context)
            halation = glow
        }
        func box(_ input: any MTLTexture, _ output: any MTLTexture, radius: Int) throws {
            var p = BoxUniform(radius: UInt32(radius), vertical: 0, width: UInt32(width), height: UInt32(height))
            try context.dispatch("graphBox", width: width, height: height, textures: [input, temp], value: &p)
            p.vertical = 1
            try context.dispatch("graphBox", width: width, height: height, textures: [temp, output], value: &p)
        }
        try box(cells, env, radius: min(32, max(4, min(width, height) * 3 / 100)))
        try context.dispatch("graphWeights", width: width, height: height, textures: [cells, env, weights], value: &parameters)
        let radius = min(8, max(4, min(width, height) / 96))
        try box(weights, means, radius: radius)
        var unused: UInt32 = 0
        try context.dispatch("graphCoefficients", width: width, height: height, textures: [means, coefficients], value: &unused)
        try box(coefficients, smoothed, radius: radius)
        try context.dispatch("graphFinalGain", width: width, height: height, textures: [cells, smoothed, weights, expansion], value: &unused)
        guard let summary = device.makeBuffer(length: 32, options: .storageModeShared) else { throw RenderError.allocationFailed }
        try context.dispatch("graphPeak", width: 1, height: 1, textures: [peaks, expansion], buffers: [summary], value: &unused)
        try finish(command)
        let originalPeak = summary.contents().advanced(by: 16).load(as: SIMD4<Float>.self).x
        let taggedHeadroom = max(source.authoredGainMap?.baseHeadroom ?? 0, source.authoredGainMap?.alternateHeadroom ?? 0)
        var result = SpatialAnalysis(size: PixelSize(width: width, height: height), cells: cells, masks: masks,
            expansion: expansion, peaks: summary.contents().load(as: SIMD4<Float>.self),
            sourceHeadroom: max(log2(max(1, originalPeak)), log2(max(1, source.hdrImage.contentHeadroom)), Float(taggedHeadroom)))
        result.filmHalation = halation
        analysisCache = (key, result)
        return result
    }

    /// The sum of the components' separable blurs (FilmStock.blur) into `output`.
    func filmBlur(_ input: any MTLTexture, into output: any MTLTexture, components: [FilmBlurComponent],
                  truncate: Double, context: RenderNodeContext) throws {
        let pass = try context.texture(width: input.width, height: input.height, format: input.pixelFormat)
#if DEBUG || HYPERDR_FILM_PROFILE
        context.diagnosticPhase("filmBlur.passAllocated", width: pass.width, height: pass.height)
#endif
        for (index, component) in components.enumerated() {
            for vertical in [false, true] {
                let taps = FilmStock.taps(component, truncate: truncate, weighted: !vertical)
                let rows = taps.taps.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 0) }
                guard let buffer = device.makeBuffer(bytes: rows, length: rows.count * 16, options: .storageModeShared)
                    else { throw RenderError.allocationFailed }
                var u = FilmBlurUniform(radius: Int32(taps.radius), vertical: vertical ? 1 : 0,
                                        accumulate: vertical && index > 0 ? 1 : 0, unused: 0)
                try context.dispatch("filmBlur", width: input.width, height: input.height,
                                     textures: vertical ? [pass, output] : [input, pass], buffers: [buffer], value: &u)
            }
        }
    }

    func graphConfiguration(_ source: RenderSource, _ edit: RenderAdjustments, analysis: SpatialAnalysis, modelPeak: Float = 0) throws -> (range: Float, expand: Bool, shoulder: Bool) {
        let expand = (edit.hdr.source ?? .defaultSource(for:source.domain)).expands
        let imported = source.domain == .hdr || source.domain == .dual
        let captured = min(imported ? Float(Adjustments.declaration("hdr.range")!.range!.upperBound) : Float(Adjustments.generatedRangeCeiling),
            max(imported ? analysis.sourceHeadroom : 0, log2(max(1, analysis.peaks.x))))
        let contentExpansion = 0.5 + (Adjustments.generatedRangeCeiling-0.5) * DoubleReference.smoothStep(0.5, 1, Double(analysis.peaks.y))
        let automatic = max(expand ? max(captured, Float(contentExpansion)) : captured,
                            min(Float(Adjustments.generatedRangeCeiling),modelPeak))
        let range = edit.hdr.range ?? automatic
        let requested = max(analysis.peaks.z, modelPeak, expand ? analysis.peaks.w * range / 3 : 0) * edit.hdr.strength
        // Use the actual post-adjustment HDR peak when captured strength is
        // unchanged, rather than an independent gain bound for a dimmer base.
        let overflow = !expand && modelPeak == 0 && edit.hdr.strength == 1
            ? analysis.peaks.x > exp2(range) * 1.00001 : requested > range + 0.00001
        return (range, expand, overflow)
    }

    /// All light/color operations, LUT, captured/analytic HDR and SDR rolloff.
    /// The empty/default dual graph returns the original author pair unchanged.
    public func render(_ source: RenderSource, adjustments edit: RenderAdjustments,
                       size: PixelSize? = nil, region: CGRect? = nil) throws -> RenderPlanes {
        try Task.checkCancellation()
        try edit.validate(domain:source.domain)
        let size = size ?? source.size
        try validate(size)
        let region = try validatedRegion(region, size: size)
        if source.domain == .dual && edit.wholeImageIsIdentity {
            if edit.hdr.isIdentity { return try renderRegion(source, size: size, region: region, nodes: []) }
            return try renderAuthorRegion(source, edit: edit, size: size, region: region)
        }
        let analysis = try analysis(source, adjustments: edit)
        return try graphRegionInBands(source, edit: edit, size: size, region: region, analysis: analysis)
    }

    /// Rows of one band when film scatter renders a tall region.
    static let filmBandRows = 256

    /// Film scatter works on three float32 textures over the region and its
    /// halo (48 B/pixel). A preview or detail region taller than four bands
    /// renders in bands of at most `filmBandRows`, copied into one output, so
    /// only one band's workspace is alive. A region renders exactly the pixels
    /// of the whole render (FilmTests), so the output is the same. Export
    /// bands (at most 516 rows) render as one region.
    func graphRegionInBands(_ source: RenderSource, edit: RenderAdjustments, size: PixelSize,
                            region: CGRect, analysis: SpatialAnalysis) throws -> RenderPlanes {
        let height = Int(region.height)
        guard (edit.sourceHalo(size: size) > 0 || !edit.effects.isIdentity), height > 4 * Self.filmBandRows else {
            return try graphRegion(source, edit: edit, size: size, region: region, analysis: analysis)
        }
        let count = (height + Self.filmBandRows - 1) / Self.filmBandRows
        let rows = (height + count - 1) / count
        var output: RenderPlanes?
        for top in stride(from: 0, to: height, by: rows) {
            try Task.checkCancellation()
            try autoreleasepool {
                let band = CGRect(x: region.minX, y: region.minY + CGFloat(top),
                                  width: region.width, height: CGFloat(min(rows, height - top)))
                let part = try graphRegion(source, edit: edit, size: size, region: band, analysis: analysis)
                if output == nil {
                    guard let allocation = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
                    let context = nodeContext(domain: source.domain, buffer: allocation)
                    output = RenderPlanes(
                        base: try context.texture(width: Int(region.width), height: height, format: part.base.pixelFormat),
                        gain: try context.texture(width: Int(region.width), height: height, format: part.gain.pixelFormat),
                        gainChannelCount: part.gainChannelCount, encoding: part.encoding, baseColorSpace: part.baseColorSpace,
                        provenance: part.provenance, region: region, outputSize: part.outputSize, aiPending: part.aiPending)
                }
                guard let output, let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
                    throw RenderError.allocationFailed
                }
                for (from, to) in [(part.base, output.base), (part.gain, output.gain)] {
                    blit.copy(from: from, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: from.width, height: from.height, depth: 1), to: to,
                              destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: top, z: 0))
                }
                blit.endEncoding()
                try finish(command)
            }
        }
        return output!
    }

    /// Regions use integral output pixels, top-left origin, within the full `size`.
    /// Analysis remains global; rendering a crop cannot change local processing.
    func validatedRegion(_ requested: CGRect?, size: PixelSize) throws -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let requested else { return bounds }
        guard !requested.isNull, !requested.isInfinite, requested.width > 0, requested.height > 0,
              requested == requested.integral, bounds.contains(requested) else { throw RenderError.invalidRegion }
        return requested
    }

    public func renderStripes(_ source: RenderSource, adjustments edit: RenderAdjustments,
                              size: PixelSize? = nil, rows: Int = 256,
                              consume: @Sendable (RenderPlanes) throws -> Void) throws {
        try edit.validate(domain:source.domain)
        let size = size ?? source.size
        try validate(size)
        guard rows > 0 else { throw RenderError.invalidSize }
        releaseNodeOutput()
        let author = source.domain == .dual && edit.wholeImageIsIdentity
        let analysis = try author ? nil : self.analysis(source, adjustments: edit)
        for y in stride(from: 0, to: size.height, by: rows) {
            try Task.checkCancellation()
            try autoreleasepool {
                let region = CGRect(x: 0, y: y, width: size.width, height: min(rows, size.height-y))
                let output: RenderPlanes
                if author && edit.hdr.isIdentity { output = try renderRegion(source, size: size, region: region, nodes: []) }
                else if author { output = try renderAuthorRegion(source, edit: edit, size: size, region: region) }
                else { output = try graphRegion(source, edit: edit, size: size, region: region, analysis: analysis!) }
                try consume(output)
                try Task.checkCancellation()
            }
        }
    }

    func graphRegion(_ source: RenderSource, edit: RenderAdjustments, size: PixelSize,
                     region: CGRect, analysis: SpatialAnalysis) throws -> RenderPlanes {
#if DEBUG || HYPERDR_FILM_PROFILE
        RenderPipelineDiagnostics.phase("graphRegion.begin", device: device, width: Int(region.width), height: Int(region.height))
#endif
        let model = try filteredModelGain(source,edit:edit)
        let configuration = try graphConfiguration(source, edit, analysis: analysis, modelPeak:model?.peak ?? 0)
        let halo = edit.sourceHalo(size: size)
        let inputRegion = region.insetBy(dx: CGFloat(-halo), dy: CGFloat(-halo))
            .intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let target = try authoredSourceAtOutputGrid(source, size: size, region: inputRegion)
        let input = try target?.hdr ?? workingInput(source)
        let resources = try lookupResources(edit.look.isIdentity ? nil : edit.look.lut)
        let film = try filmResources(edit.film, active: edit.usesFilmProcessing, genericGrain: edit.film.stock == nil && edit.effects.grain > 0)
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let context = nodeContext(domain: source.domain, buffer: command)
#if DEBUG || HYPERDR_FILM_PROFILE
        context.diagnosticPhase("graphRegion.inputReady", width: input.width, height: input.height)
#endif
        let base = try context.texture(width: Int(region.width), height: Int(region.height))
        let partialLUT = !edit.look.isIdentity && edit.look.strength < 1
        let partialFilm = !edit.film.isIdentity && edit.film.strength < 1
        let rgbGain = source.domain == .dual || (partialLUT && !(edit.look.input.isSDR && edit.look.output.isSDR)) || partialFilm || (!edit.effects.isIdentity && (edit.film.stock == nil || edit.film.strength < 1))
        let gain = try context.texture(width: base.width, height: base.height, format: rgbGain ? .rgba32Float : .r32Float)
#if DEBUG || HYPERDR_FILM_PROFILE
        context.diagnosticPhase("graphRegion.outputsAllocated", width: base.width, height: base.height)
#endif
        var p = graphUniform(source, edit, size: size, region: region, range: configuration.range,
            shoulder: configuration.shoulder)
        if let target { p.inputRegion = sourceSampling(target.source.texture, target.source.samplingRegion) }
        p.mode.x = configuration.expand ? 1 : 0
        p.mode.y = model == nil ? 0 : 1
        if analysis.filmHalation != nil, edit.usesFilmProcessing, let stock = edit.film.stock, let data = try? FilmStock.named(stock) {
            p.halation = SIMD4(SIMD3<Float>(data.halationStrength(edit.film, amount: edit.effects.halation)), 1)
        }
        var scattered: (any MTLTexture)?
        if halo > 0, let stock = edit.film.stock {
            // In-emulsion scatter at the render's own resolution: film exposure of the
            // region and its halo, blurred, read in place of the render's own.
            let around = region.insetBy(dx: CGFloat(-halo), dy: CGFloat(-halo))
                .intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            var q = p
            q.region = SIMD4(UInt32(size.width), UInt32(size.height), UInt32(around.minX), UInt32(around.minY))
            // Scatter integrates linear exposure before the film's nonlinear curves.
            // Half floats both clip bright exposures at 65504 and accumulate enough
            // rounding error to move ordinary SDR colours by several 10-bit codes.
            let raw = try context.texture(width: Int(around.width), height: Int(around.height), format: .rgba32Float)
#if DEBUG || HYPERDR_FILM_PROFILE
            context.diagnosticPhase("film.exposureAllocated", width: raw.width, height: raw.height)
#endif
            try context.dispatch("graphFilmExposure", width: raw.width, height: raw.height,
                textures: [input, raw, resources.texture, film.texture], buffers: [resources.buffer, film.buffer], value: &q)
            let exposure = try context.texture(width: raw.width, height: raw.height, format: .rgba32Float)
#if DEBUG || HYPERDR_FILM_PROFILE
            context.diagnosticPhase("film.scatterAllocated", width: exposure.width, height: exposure.height)
#endif
            try filmBlur(raw, into: exposure, components: try FilmStock.named(stock).scatterComponents(longEdge: max(size.width, size.height)),
                         truncate: FilmStock.scatterTruncate, context: context)
            p.scatter = SIMD4(Int32(region.minX - around.minX), Int32(region.minY - around.minY), 1, 0)
            scattered = exposure
#if DEBUG || HYPERDR_FILM_PROFILE
            context.diagnosticPhase("film.scatterEncoded", width: exposure.width, height: exposure.height)
#endif
        }
        // The grain's sublayer kernels depend only on this render's pixel pitch.
        let grainStock: FilmStockID? = edit.effects.grain > 0
            ? (edit.film.stock ?? .portra400) : nil
        let grainRows = grainStock.flatMap { try? FilmStock.named($0) }?
            .packedGrainKernel(longEdge: max(size.width, size.height)) ?? [SIMD4<Float>(repeating: 0)]
        guard let grainKernel = device.makeBuffer(bytes: grainRows, length: grainRows.count * 16, options: .storageModeShared)
            else { throw RenderError.allocationFailed }
        try context.dispatch("graphOutput", width: base.width, height: base.height,
            textures: [input, base, gain, resources.texture, analysis.expansion, model?.gain ?? analysis.expansion, film.texture,
                       analysis.filmHalation ?? analysis.expansion, scattered ?? analysis.expansion, try lookBaseline(target?.source ?? source, edit: edit)],
            buffers: [resources.buffer, film.buffer, grainKernel], value: &p)
#if DEBUG || HYPERDR_FILM_PROFILE
        context.diagnosticPhase("graphRegion.outputEncoded", width: base.width, height: base.height)
#endif
        try finish(command)
#if DEBUG || HYPERDR_FILM_PROFILE
        context.diagnosticPhase("graphRegion.completed", width: base.width, height: base.height)
#endif
        let encoding: GainEncoding = p.pair.x > 0
            ? .pairedLog2(offset: p.pair.x, headroom: configuration.range) : .log2
        return RenderPlanes(base: base, gain: gain, gainChannelCount: rgbGain ? 3 : 1, encoding: encoding, baseColorSpace: Self.workingColorSpace,
            provenance: source.domain == .dual ? .resplit : source.domain == .sdr ? .identity : .split, region: region, outputSize:size,
            aiPending: edit.hdr.enabled && (edit.hdr.source ?? .defaultSource(for:source.domain)).usesModel && model == nil)
    }

    func authorWorking(_ source: RenderSource) throws -> (base: any MTLTexture, hdr: any MTLTexture, metadata: ISOLogGainMetadata) {
        if let cache = authorCache, cache.id == source.renderID { return (cache.base, cache.hdr, cache.metadata) }
        authorCache = nil
        guard let original = source.authoredGainMap, let baseImage = source.authoredBaseImage else { throw RenderError.missingGainMap }
        let space = original.gainWorkingColorSpace ?? source.baseSpace
        let base = CFEqual(space, source.baseSpace) ? source.texture : try rasterize(baseImage, space: space)
        let hdr = try rasterize(source.hdrImage, space: space)
        let channels = original.isoChannels
        func vector(_ key: KeyPath<ISOGainChannel, Double>) -> SIMD3<Float> {
            guard let channels else { return .zero }
            return SIMD3(Float(channels[0][keyPath: key]), Float(channels[channels.count == 1 ? 0 : 1][keyPath: key]), Float(channels[channels.count == 1 ? 0 : 2][keyPath: key]))
        }
        let metadata = ISOLogGainMetadata(source: original, workingColorSpace: space,
            baseOffset: vector(\.baseOffset), alternateOffset: vector(\.alternateOffset))
        authorCache = (source.renderID, base, hdr, metadata)
        return (base, hdr, metadata)
    }

    func renderAuthorRegion(_ source: RenderSource, edit: RenderAdjustments, size: PixelSize, region: CGRect) throws -> RenderPlanes {
        let original = try renderRegion(source, size: size, region: region, nodes: [])
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let context = nodeContext(domain: .dual, buffer: command)
        let gain = try context.texture(width: original.base.width, height: original.base.height,
                                       format: edit.hdr.enabled ? .rgba32Float : .r32Float)
        if !edit.hdr.enabled {
            var unused: UInt32 = 0
            try context.dispatch("zeroGain", width: gain.width, height: gain.height, textures: [gain], value: &unused)
            try finish(command)
            return RenderPlanes(base: original.base, gain: gain, baseColorSpace: original.baseColorSpace, provenance: .editedAuthored, region: region, outputSize:size)
        }
        let working = try authorWorking(source)
        // Analysis only resolves content headroom; it never replaces the author's base.
        let analysis = try self.analysis(source)
        let natural = min(Float(Adjustments.declaration("hdr.range")!.range!.upperBound), max(analysis.sourceHeadroom, log2(max(1, analysis.peaks.x))))
        let range = edit.hdr.range ?? natural
        let localBase = source.authoredGainMap?.hasCanonicalSDRBase == true
        let workingBase: any MTLTexture
        if localBase {
            // renderRegion normalized the reverse source at this output grid.
            // Re-sampling its native SDR endpoint would undo that guarantee.
            if CFEqual(original.baseColorSpace, working.metadata.workingColorSpace) { workingBase = original.base }
            else {
                workingBase = try context.texture(width: original.base.width, height: original.base.height)
                var matrix = simd_inverse(try displayMatrixToP3(working.metadata.workingColorSpace))
                    * (try displayMatrixToP3(original.baseColorSpace))
                try context.dispatch("displayBase", width: workingBase.width, height: workingBase.height,
                    textures: [original.base, workingBase], value: &matrix)
            }
        } else { workingBase = working.base }
        let channels = working.metadata.source.isoChannels
        func vector(_ key: KeyPath<ISOGainChannel, Double>, fallback: Float) -> SIMD4<Float> {
            guard let channels else { return SIMD4(repeating: fallback) }
            return SIMD4(Float(channels[0][keyPath:key]), Float(channels[channels.count == 1 ? 0 : 1][keyPath:key]), Float(channels[channels.count == 1 ? 0 : 2][keyPath:key]), 0)
        }
        let maxGain = vector(\.maximum, fallback: max(0, log2(max(1, analysis.peaks.x))))
        let shoulder = max(maxGain.x, max(maxGain.y, maxGain.z)) * edit.hdr.strength > range + 0.00001
        var p = AuthorUniform(minimum: vector(\.minimum, fallback: 0), maximum: maxGain,
            inverseGamma: 1 / vector(\.gamma, fallback: 1), baseOffset: SIMD4(working.metadata.baseOffset,0),
            alternateOffset: SIMD4(working.metadata.alternateOffset,0),
            controls: SIMD4(edit.hdr.strength, range, Float(size.width), Float(size.height)),
            info: SIMD4(UInt32(working.metadata.source.channelCount), (channels == nil ? 0 : 1) | (shoulder ? 2 : 0) | (localBase ? 4 : 0), UInt32(region.minX), UInt32(region.minY)),
            inputRegion:sourceSampling(source.texture,source.samplingRegion),gainRegion:sourceSampling(source.gainTexture!,source.gainSamplingRegion))
        try context.dispatch("authoredOutput", width: gain.width, height: gain.height,
            textures: [workingBase, source.gainTexture!, working.hdr, gain], value: &p)
        try finish(command)
        return RenderPlanes(base: original.base, gain: gain, gainChannelCount: 3, encoding: .isoLog2(working.metadata),
                            baseColorSpace: original.baseColorSpace, provenance: .editedAuthored, region: region, outputSize:size)
    }
}
