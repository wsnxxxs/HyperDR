import Foundation
import CoreImage
import ImageIO
import Metal
import simd
import HyperDRRecipe

private struct ExportUniform {
    var toGain,toP3: simd_float3x3
    var baseOffset,alternateOffset: SIMD4<Float>
    var info: SIMD4<UInt32>
    var controls: SIMD4<Float>
    init(_ pair: DisplayGainPair, resplit: Bool = false, flatten: Bool = false,
         sdrOnly: Bool = false, ceiling: Float = 1, shoulder: Bool = false) {
        toGain = pair.p3ToGain; toP3 = pair.gainToP3
        baseOffset = SIMD4(pair.baseOffset,0); alternateOffset = SIMD4(pair.alternateOffset,0)
        info = SIMD4(UInt32(pair.gainChannelCount),resplit ? 1 : 0,flatten ? 1 : 0,sdrOnly ? 1 : 0)
        controls = SIMD4(ceiling,shoulder ? 1 : 0,0,0)
    }
}
/// Preparation retains metadata, never a first band's GPU textures.
private struct ExportPairInfo {
    let gainChannelCount: Int
    let baseOffset,alternateOffset: SIMD3<Float>
    let baseHeadroom,alternateHeadroom: Float
    let p3ToGain,gainToP3: simd_float3x3
    let isSimpleGain: Bool
    init(_ pair: DisplayGainPair) {
        gainChannelCount = pair.gainChannelCount
        baseOffset = pair.baseOffset; alternateOffset = pair.alternateOffset
        baseHeadroom = pair.baseHeadroom; alternateHeadroom = pair.alternateHeadroom
        p3ToGain = pair.p3ToGain; gainToP3 = pair.gainToP3; isSimpleGain = pair.isSimpleGain
    }
}
private struct FrameUniform {
    var photo,caption: SIMD4<UInt32>
    var paper,shadow: SIMD4<Float>
    var region: SIMD4<UInt32>
}

// Caption texture is immutable and used only on its owning renderer executor.
private struct ExportPreparation: @unchecked Sendable {
    let source: RenderSource
    let lazy: ExportSource?
    let request: ExportRenderRequest
    let edit: RenderAdjustments
    let caption: (any MTLTexture)?
    let report: ExportRenderReport
    let transparent, resplit, shoulder: Bool
    let ceiling: Float
}

extension RenderEngine: ExportStripeRendering {
    public func renderExportStripes(_ source: RenderSource, recipe: Recipe, lut: ColorLUT? = nil,
                                    modelGain: ModelGainPrediction? = nil, request: ExportRenderRequest, rows: Int = 256,
                                    prepare: @Sendable (ExportRenderReport) throws -> Void,
                                    consume: @Sendable (ExportStripe) throws -> Void) throws -> ExportRenderReport {
        try renderExport(source,lazy:nil,recipe:recipe,lut:lut,modelGain:modelGain,request:request,rows:rows,prepare:prepare,consume:consume)
    }

    /// Lazy source overload: no full-size RenderSource or RGBAf input texture.
    public func renderExportStripes(_ source: ExportSource, recipe: Recipe, lut: ColorLUT? = nil,
                                    modelGain: ModelGainPrediction? = nil, request: ExportRenderRequest, rows: Int = 256,
                                    prepare: @Sendable (ExportRenderReport) throws -> Void,
                                    consume: @Sendable (ExportStripe) throws -> Void) throws -> ExportRenderReport {
        try renderExport(source.analysisSource,lazy:source,recipe:recipe,lut:lut,modelGain:modelGain,
                         request:request,rows:rows,prepare:prepare,consume:consume)
    }

    private func renderExport(_ source: RenderSource, lazy: ExportSource?, recipe: Recipe, lut: ColorLUT?,
                              modelGain: ModelGainPrediction?, request: ExportRenderRequest, rows: Int,
                              prepare: @Sendable (ExportRenderReport) throws -> Void,
                              consume: @Sendable (ExportStripe) throws -> Void) throws -> ExportRenderReport {
        let prepared = try prepareExport(source,lazy:lazy,recipe:recipe,lut:lut,modelGain:modelGain,request:request,rows:rows)
        try Task.checkCancellation()
        try prepare(prepared.report)
        for y in stride(from:0,to:request.canvasSize.height,by:rows) {
            try consume(readExport(prepared,y:y,count:min(rows,request.canvasSize.height-y)))
        }
        return prepared.report
    }

    private func prepareExport(_ source: RenderSource, lazy: ExportSource?, recipe: Recipe, lut: ColorLUT?,
                               modelGain: ModelGainPrediction?, request: ExportRenderRequest, rows: Int) throws -> ExportPreparation {
        try Task.checkCancellation()
        guard source.domain == recipe.inputDomain, rows > 0 else { throw RenderError.invalidAdjustment }
        try validate(request.photoSize); try validate(request.canvasSize)
        if let limit = request.ceilingStops {
            guard limit.isFinite, limit >= 0.5, limit <= 4 else { throw RenderError.invalidAdjustment }
        }
        var edit = try RenderAdjustments(recipe:recipe,lut:lut)
        edit.hdr.modelGain = modelGain
        if edit.hdr.enabled && (edit.hdr.source ?? .defaultSource(for:source.domain)).usesModel {
            guard let modelGain, modelGain.sourceID == source.id else { throw RenderError.aiNotAvailable }
        }
        var automatic = try resolvedAutomatic(source,recipe:recipe,lut:lut,modelGain:modelGain)
        let naturalRange = edit.hdr.range ?? Float(automatic["hdr.range"] ?? 0)
        if let limit = request.ceilingStops, limit < naturalRange {
            edit.hdr.range = limit
            if automatic["hdr.range"] != nil { automatic["hdr.range"] = Double(limit) }
        }
        let caption = try exportCaption(request.frame,photoSize:request.photoSize)
        // Header must be global, including signed gain and transparency that a
        // fixed-scale analysis can miss. Scan GPU bands, retain only five words.
        var summary = SIMD8<UInt32>.zero
        var firstPair: ExportPairInfo?, provenance = PairProvenance.identity
        for y in stride(from:0,to:request.photoSize.height,by:rows) {
            try Task.checkCancellation()
            try autoreleasepool {
                let tile = try lazy.map { try materializeExportRegion($0,outputSize:request.photoSize,
                    region:CGRect(x:0,y:y,width:request.photoSize.width,height:min(rows,request.photoSize.height-y))) } ?? source
                let planes = try render(tile,adjustments:edit,size:request.photoSize,
                    region:CGRect(x:0,y:y,width:request.photoSize.width,height:min(rows,request.photoSize.height-y)))
                guard !planes.aiPending else { throw RenderError.aiNotAvailable }
                let pair = try displayPair(planes,source:tile)
                if firstPair == nil { firstPair = ExportPairInfo(pair); provenance = planes.provenance }
                guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
                let node = nodeContext(domain:source.domain,buffer:command)
                guard let stats = device.makeBuffer(length:32,options:.storageModeShared) else { throw RenderError.allocationFailed }
                stats.contents().initializeMemory(as:UInt8.self,repeating:0,count:32)
                var p = ExportUniform(pair)
                try node.dispatch("exportSummary",width:pair.base.width,height:pair.base.height,
                                  textures:[pair.base,pair.gain],buffers:[stats],value:&p)
                try finish(command)
                let words = stats.contents().bindMemory(to:UInt32.self,capacity:8)
                for i in 0..<5 { summary[i] = max(summary[i],words[i]) }
            }
        }
        let pair = firstPair!
        guard summary[4] == 0 else { throw RenderError.invalidAdjustment }
        let maxGain = Float(bitPattern:summary[0]), signed = summary[1] != 0, transparent = summary[2] != 0
        let hdrPeak = Float(bitPattern:summary[3])
        guard maxGain.isFinite && hdrPeak.isFinite else { throw RenderError.invalidAdjustment }
        let authored = source.domain == .dual && edit.wholeImageIsIdentity && edit.hdr.enabled
        let declaredHeadroom = min(authored ? pair.alternateHeadroom : maxGain,request.ceilingStops ?? .infinity)
        var reasons: Set<ExportResplitReason> = []
        let caps = request.capabilities
        func isP3(_ matrix: simd_float3x3) -> Bool {
            (0..<3).allSatisfy { simd_reduce_max(abs(matrix[$0]-matrix_identity_float3x3[$0])) < 0.00001 }
        }
        if request.includesGain {
            if !isP3(pair.p3ToGain) || !isP3(pair.gainToP3) { reasons.insert(.unsupportedGainWorkingGamut) }
            if pair.gainChannelCount == 3 && !caps.supportsThreeChannelGain { reasons.insert(.writerCarriesOneChannel) }
            if !caps.supportsNonzeroOffsets && (pair.baseOffset != .zero || pair.alternateOffset != .zero) {
                reasons.insert(.writerCannotRepresentOffsets)
            }
            if signed && !caps.supportsSignedGain { reasons.insert(.writerCannotRepresentSignedGain) }
            if caps.requiresGainMaximumHeadroom && (pair.baseHeadroom != 0 || maxGain > declaredHeadroom+0.00001) {
                reasons.insert(.writerHeadroomContract)
            }
            if request.frame != nil && pair.baseOffset != pair.alternateOffset { reasons.insert(.frameRequiresNeutralPair) }
            if transparent && !pair.isSimpleGain { reasons.insert(.flattenTransparency) }
            if pair.baseHeadroom > declaredHeadroom { reasons.insert(.outputCeiling) }
        }
        let ceiling = request.ceilingStops.map { exp2($0) } ?? .infinity
        let shoulder = request.includesGain && hdrPeak > ceiling*1.00001
        if shoulder { reasons.insert(.outputCeiling) }
        let resplit = !reasons.isEmpty
        let metadata: ExportGainMetadata?
        if !request.includesGain { metadata = nil }
        else if resplit {
            metadata = ExportGainMetadata(channelCount:1,alternateHeadroom:min(log2(max(1,hdrPeak)),request.ceilingStops ?? .infinity))
        } else {
            // Generated gains have no authored capacity; use the exact full-image
            // maximum, rather than a header that depends on which stripe came first.
            metadata = ExportGainMetadata(channelCount:pair.gainChannelCount,baseOffset:pair.baseOffset,
                alternateOffset:pair.alternateOffset,baseHeadroom:pair.baseHeadroom,
                alternateHeadroom:declaredHeadroom)
        }
        let sourceProvenance = provenance
        if resplit { provenance = .resplit }
        let report = ExportRenderReport(canvasSize:request.canvasSize,gain:metadata,sourceProvenance:sourceProvenance,provenance:provenance,
            resplitReasons:reasons,rangeBeforeCeiling:naturalRange,
            rangeAfterCeiling:edit.hdr.range ?? naturalRange,resolvedAutomatic:automatic,presentationFrame:request.frame != nil,
            framePhoto:request.frame?.photo)
        return ExportPreparation(source:source,lazy:lazy,request:request,edit:edit,caption:caption,report:report,
                                 transparent:transparent,resplit:resplit,shoulder:shoulder,ceiling:ceiling)
    }

    private func readExport(_ state: ExportPreparation, y: Int, count: Int) throws -> ExportStripe {
        let source = state.source, lazy = state.lazy, request = state.request, edit = state.edit
        let metadata = state.report.gain, caption = state.caption
        let resplit = state.resplit, transparent = state.transparent, ceiling = state.ceiling, shoulder = state.shoulder
        guard y >= 0, count > 0, y < request.canvasSize.height, count <= request.canvasSize.height-y else {
            throw RenderError.invalidRegion
        }
        try Task.checkCancellation()
        if let lazy { try lazy.revision.validate(lazy.url) }
        return try autoreleasepool {
            let height = count
            let photo = request.frame?.photo ?? ExportRect(x:0,y:0,width:request.photoSize.width,height:request.photoSize.height)
            let start = max(y,photo.y), end = min(y+height,photo.y+photo.height)
            var photoPlanes: RenderPlanes?
            if start < end {
                let region = CGRect(x:0,y:start-photo.y,width:photo.width,height:end-start)
                let tile = try lazy.map { try materializeExportRegion($0,outputSize:request.photoSize,region:region) } ?? source
                let rendered = try render(tile,adjustments:edit,size:request.photoSize,region:region)
                let pair = try displayPair(rendered,source:tile)
                photoPlanes = try exportNormalize(pair,source:source,channels:metadata?.channelCount ?? 1,
                    resplit:resplit,flatten:transparent,sdrOnly:!request.includesGain,ceiling:ceiling,shoulder:shoulder)
            }
            let output: RenderPlanes
            if let frame = request.frame {
                output = try exportFrame(photoPlanes,source:source,frame:frame,caption:caption,
                                         y:y,height:height,photoStart:start,channels:metadata?.channelCount ?? 1)
            } else { output = photoPlanes! }
            let rgba = Self.readTexture(output.base)
            var rgb = [Float](); rgb.reserveCapacity(output.base.width*output.base.height*3)
            for i in stride(from:0,to:rgba.count,by:4) { rgb.append(contentsOf:rgba[i..<i+3]) }
            let gain: [Float]
            if let metadata {
                let values = Self.readTexture(output.gain)
                if metadata.channelCount == 1 { gain = values }
                else {
                    var packed = [Float](); packed.reserveCapacity(output.gain.width*output.gain.height*3)
                    for i in stride(from:0,to:values.count,by:4) { packed.append(contentsOf:values[i..<i+3]) }
                    gain = packed
                }
            } else { gain = [] }
            try Task.checkCancellation()
            return ExportStripe(rect:ExportRect(x:0,y:y,width:request.canvasSize.width,height:height),baseRGB:rgb,gain:gain)
        }
    }

    /// Freezes one global scan in a dedicated renderer. The originating engine
    /// remains available for preview and other exports while the reader is alive.
    public func prepareExportRows(_ source: ExportSource, recipe: Recipe, lut: ColorLUT? = nil,
                                  modelGain: ModelGainPrediction? = nil, request: ExportRenderRequest) async throws -> PreparedExportRows {
        let renderer = try RenderEngine(device:device)
        return try await renderer.makeExportRows(source,recipe:recipe,lut:lut,modelGain:modelGain,request:request)
    }

    private func makeExportRows(_ source: ExportSource, recipe: Recipe, lut: ColorLUT?,
                                modelGain: ModelGainPrediction?, request: ExportRenderRequest) throws -> PreparedExportRows {
        analysisSource = source.analysisSource
        let state = try prepareExport(source.analysisSource,lazy:source,recipe:recipe,lut:lut,
                                      modelGain:modelGain,request:request,rows:256)
        return PreparedExportRows(report:state.report) { [self] y,count in
            try serialExecutor.sync {
                try self.assumeIsolated { renderer in try renderer.readExport(state,y:y,count:count) }
            }
        }
    }

    private func exportNormalize(_ pair: DisplayGainPair, source: RenderSource, channels: Int,
                                 resplit: Bool, flatten: Bool, sdrOnly: Bool, ceiling: Float, shoulder: Bool) throws -> RenderPlanes {
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let node = nodeContext(domain:source.domain,buffer:command)
        let base = try node.texture(width:pair.base.width,height:pair.base.height)
        let gain = try node.texture(width:base.width,height:base.height,format:channels == 1 ? .r32Float : .rgba32Float)
        var p = ExportUniform(pair,resplit:resplit,flatten:flatten,sdrOnly:sdrOnly,ceiling:ceiling,shoulder:shoulder)
        try node.dispatch("exportPair",width:base.width,height:base.height,textures:[pair.base,pair.gain,base,gain],value:&p)
        try finish(command)
        return RenderPlanes(base:base,gain:gain,gainChannelCount:channels,baseColorSpace:Self.workingColorSpace,
                            provenance:.identity,region:pair.region,outputSize:pair.outputSize)
    }

    private func exportCaption(_ frame: FrameSnapshot?, photoSize: PixelSize) throws -> (any MTLTexture)? {
        guard let frame else { return nil }
        func contains(_ r: ExportRect) -> Bool {
            r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0 && r.x <= frame.canvasSize.width-r.width && r.y <= frame.canvasSize.height-r.height
        }
        guard contains(frame.photo), frame.photo.width == photoSize.width, frame.photo.height == photoSize.height,
              (frame.photo.x % 2 == 0 && frame.photo.y % 2 == 0),
              frame.paper.x.isFinite && frame.paper.y.isFinite && frame.paper.z.isFinite,
              simd_reduce_min(frame.paper) >= 0 && simd_reduce_max(frame.paper) <= 1,
              frame.shadow.opacity.isFinite && (0...1).contains(frame.shadow.opacity),
              frame.shadow.sigma.isFinite && frame.shadow.sigma >= 0,
              frame.shadow.offset.x.isFinite && frame.shadow.offset.y.isFinite else { throw RenderError.invalidAdjustment }
        guard let caption = frame.caption else { return nil }
        guard contains(caption.rect), let source = CGImageSourceCreateWithData(caption.png as CFData,nil),
              (CGImageSourceGetType(source) as String?) == "public.png",
              let image = CIImage(data:caption.png), image.extent.width == Double(caption.rect.width),
              image.extent.height == Double(caption.rect.height) else { throw RenderError.invalidAdjustment }
        let photo = CGRect(x:frame.photo.x,y:frame.photo.y,width:frame.photo.width,height:frame.photo.height)
        let band = CGRect(x:caption.rect.x,y:caption.rect.y,width:caption.rect.width,height:caption.rect.height)
        guard !photo.intersects(band) else { throw RenderError.invalidAdjustment }
        return try rasterize(image,space:Self.workingColorSpace)
    }

    private func exportFrame(_ photo: RenderPlanes?, source: RenderSource, frame: FrameSnapshot,
                             caption: (any MTLTexture)?, y: Int, height: Int, photoStart: Int, channels: Int) throws -> RenderPlanes {
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let node = nodeContext(domain:source.domain,buffer:command)
        let base = try node.texture(width:frame.canvasSize.width,height:height)
        let gain = try node.texture(width:base.width,height:height,format:channels == 1 ? .r32Float : .rgba32Float)
        let dummy = try node.texture(width:1,height:1)
        func vector(_ r: ExportRect) -> SIMD4<UInt32> { SIMD4(UInt32(r.x),UInt32(r.y),UInt32(r.width),UInt32(r.height)) }
        var p = FrameUniform(photo:vector(frame.photo),caption:frame.caption.map { vector($0.rect) } ?? .zero,
            paper:SIMD4(frame.paper,1),shadow:SIMD4(frame.shadow.opacity,frame.shadow.sigma,frame.shadow.offset.x,frame.shadow.offset.y),
            region:SIMD4(UInt32(y),UInt32(max(0,photoStart)),photo == nil ? 0 : 1,caption == nil ? 0 : 1))
        try node.dispatch("exportFrame",width:base.width,height:height,
            textures:[photo?.base ?? dummy,photo?.gain ?? dummy,caption ?? dummy,base,gain],value:&p)
        try finish(command)
        return RenderPlanes(base:base,gain:gain,gainChannelCount:channels,baseColorSpace:Self.workingColorSpace,
                            provenance:.identity,region:CGRect(x:0,y:y,width:base.width,height:height),outputSize:frame.canvasSize)
    }
}
