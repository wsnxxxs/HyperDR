import Foundation
import CoreImage
import Metal
import simd

/// Display-only ISO pair. Base pixels are extended-linear Display P3; gain is
/// decoded log2 in its original linear working gamut. Textures have top-down rows.
/// Matrices multiply column vectors, as in Metal's float3x3. Headrooms are log2 stops.
///
/// At ISO weight w: gainToP3 * ((p3ToGain * base + baseOffset) * exp2(w * gain) - alternateOffset).
/// A mono gain texture's red component is replicated across RGB. Sample gain at
/// normalized coordinates: its resolution can differ from the base's resolution.
/// This representation never replaces the original export RenderPlanes.
public struct DisplayGainPair: @unchecked Sendable {
    public let base: any MTLTexture
    public let gain: any MTLTexture
    public let gainChannelCount: Int
    public let baseOffset: SIMD3<Float>
    public let alternateOffset: SIMD3<Float>
    public let baseHeadroom: Float
    public let alternateHeadroom: Float
    public let p3ToGain: simd_float3x3
    public let gainToP3: simd_float3x3
    public let region: CGRect
    public let outputSize: PixelSize
    public var size: PixelSize { PixelSize(width:base.width,height:base.height) }
    public var isSimpleGain: Bool {
        baseOffset == .zero && alternateOffset == .zero &&
        p3ToGain == matrix_identity_float3x3 && gainToP3 == matrix_identity_float3x3
    }

    public init(base: any MTLTexture, gain: any MTLTexture, gainChannelCount: Int = 1,
                baseOffset: SIMD3<Float> = .zero, alternateOffset: SIMD3<Float> = .zero,
                baseHeadroom: Float = 0, alternateHeadroom: Float,
                p3ToGain: simd_float3x3 = matrix_identity_float3x3,
                gainToP3: simd_float3x3 = matrix_identity_float3x3, region: CGRect, outputSize: PixelSize? = nil) {
        self.base = base; self.gain = gain; self.gainChannelCount = gainChannelCount
        self.baseOffset = baseOffset; self.alternateOffset = alternateOffset
        self.baseHeadroom = baseHeadroom; self.alternateHeadroom = alternateHeadroom
        self.p3ToGain = p3ToGain; self.gainToP3 = gainToP3; self.region = region
        self.outputSize = outputSize ?? PixelSize(width:base.width,height:base.height)
    }
}

private struct DisplayISOUniform {
    var minimum, maximum, inverseGamma: SIMD4<Float>
    var channels: SIMD4<UInt32>
    var output: SIMD4<UInt32>
    var sourceRegion: SIMD4<Float>
}
private struct CanonicalISOUniform {
    var baseToGain, gainToBase: simd_float3x3
    var minimum, maximum, inverseGamma: SIMD4<Float>
    var baseOffset, alternateOffset: SIMD4<Float>
    var output: SIMD4<UInt32>
    var gainRegion: SIMD4<Float>
    var channels: SIMD4<UInt32>
}
private struct DisplayLegacyUniform {
    var gainToP3: simd_float3x3
    var baseOffset, alternateOffset: SIMD4<Float>
    var region: SIMD4<Float>
    var size,inputRegion: SIMD4<Float>
}
private struct DisplayHDRUniform {
    var p3ToGain, gainToP3: simd_float3x3
    var baseOffset, alternateOffset: SIMD4<Float>
    var channels: SIMD4<UInt32>
}

extension RenderEngine {
    /// Preserve reverse ISO's complete display curve while giving the editor its
    /// SDR endpoint. If S=(B+oB)*2^-g-oA, then (S+oA)*2^(w*g)-oA equals the
    /// native negative-weight reconstruction at w-1, including unequal offsets.
    /// The original encoded gain and metadata dictionaries stay available.
    func canonicalizeAuthoredSource(_ source: RenderSource) throws -> RenderSource {
        guard var metadata = source.authoredGainMap, metadata.needsSDRBaseNormalization else { return source }
        guard metadata.nativeISOChannels != nil else { throw RenderError.missingGainMap }
        let baseWindow = sourceSampling(source.texture, source.samplingRegion)
        let base = try canonicalISOBase(source.texture, source: source,
            size: PixelSize(width: Int(baseWindow.z), height: Int(baseWindow.w)),
            origin: SIMD2(UInt32(baseWindow.x), UInt32(baseWindow.y)))
        metadata.hasCanonicalSDRBase = true
        let image = CIImage(mtlTexture: base, options: [.colorSpace: source.baseSpace])!
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(base.height)))
        var normalized = RenderSource(id: source.id, renderID: source.renderID, origin: source.origin,
            domain: source.domain, size: source.size, nativeSize: source.nativeSize,
            authoredGainMap: metadata, hdrImage: source.hdrImage, authoredBaseImage: image,
            rawSettings: source.rawSettings, texture: base, baseSpace: source.baseSpace, gainTexture: source.gainTexture)
        normalized.samplingRegion = source.samplingRegion
        normalized.gainSamplingRegion = source.gainSamplingRegion
        normalized.geometryUncroppedSize = source.geometryUncroppedSize
        return normalized
    }

    /// Normalize at the requested pixel grid. Resizing a previously normalized
    /// SDR image and gain independently would change the HDR endpoint near edges.
    func canonicalISOBase(_ base: any MTLTexture, source: RenderSource, size: PixelSize,
                          origin: SIMD2<UInt32>) throws -> any MTLTexture {
        guard let metadata = source.authoredGainMap, let channels = metadata.isoChannels,
              let encoded = source.gainTexture else { throw RenderError.missingGainMap }
        let gainSpace = metadata.gainWorkingColorSpace ?? source.baseSpace
        let baseToGain = CFEqual(gainSpace, source.baseSpace) ? matrix_identity_float3x3
            : simd_inverse(try displayMatrixToP3(gainSpace)) * (try displayMatrixToP3(source.baseSpace))
        func vector(_ key: KeyPath<ISOGainChannel, Double>) -> SIMD4<Float> {
            SIMD4(Float(channels[0][keyPath: key]), Float(channels[channels.count == 1 ? 0 : 1][keyPath: key]),
                  Float(channels[channels.count == 1 ? 0 : 2][keyPath: key]), 0)
        }
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let node = nodeContext(domain: source.domain, buffer: command)
        let result = try node.texture(width: base.width, height: base.height)
        var p = CanonicalISOUniform(baseToGain: baseToGain, gainToBase: simd_inverse(baseToGain),
            minimum: vector(\.minimum), maximum: vector(\.maximum), inverseGamma: 1 / vector(\.gamma),
            baseOffset: vector(\.baseOffset), alternateOffset: vector(\.alternateOffset),
            output: SIMD4(UInt32(size.width), UInt32(size.height), origin.x, origin.y),
            gainRegion: sourceSampling(encoded, source.gainSamplingRegion), channels: SIMD4(UInt32(metadata.channelCount), 0, 0, 0))
        try node.dispatch("canonicalISOBase", width: result.width, height: result.height,
            textures: [base, encoded, result], value: &p)
        try finish(command)
        return result
    }

    func reconstructAuthoredHDR(_ source: RenderSource) throws -> any MTLTexture {
        guard let metadata = source.authoredGainMap, let gain = source.gainTexture else { throw RenderError.missingGainMap }
        let n = source.samplingRegion
        let x = (n.minX * CGFloat(source.size.width)).rounded()
        let y = (n.minY * CGFloat(source.size.height)).rounded()
        let region = CGRect(x: x, y: y, width: CGFloat(source.texture.width), height: CGFloat(source.texture.height))
        let planes = RenderPlanes(base: source.texture, gain: gain, gainChannelCount: metadata.channelCount,
            encoding: .authored(metadata), baseColorSpace: source.baseSpace, provenance: .authored,
            region: region, outputSize: source.size)
        let pair = try displayPair(planes, source: source)
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let output = try encodeDisplayHDR(pair, into: command)
        try finish(command)
        return output
    }

    /// A reverse pair's SDR and HDR must enter edits on the same output grid.
    /// Sampling the native normalized SDR separately would introduce a visible
    /// jump on the first nonzero light/color edit at a smaller output size.
    func authoredSourceAtOutputGrid(_ source: RenderSource, size: PixelSize, region: CGRect) throws
        -> (source: RenderSource, hdr: any MTLTexture)? {
        guard source.authoredGainMap?.hasCanonicalSDRBase == true, size != source.size else { return nil }
        let planes = try renderRegion(source, size: size, region: region, nodes: [])
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let pair = try encodeExportDisplayPair(planes, source: source, into: command)
        let hdr = try encodeDisplayHDR(pair, into: command)
        try finish(command)
        func image(_ texture: any MTLTexture) -> CIImage {
            CIImage(mtlTexture: texture, options: [.colorSpace: Self.workingColorSpace])!
                .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(texture.height)))
        }
        var target = RenderSource(id: source.id, renderID: UUID(), origin: source.origin,
            domain: source.domain, size: size, nativeSize: source.nativeSize,
            authoredGainMap: source.authoredGainMap,
            hdrImage: image(hdr).settingContentHeadroom(source.hdrImage.contentHeadroom),
            authoredBaseImage: image(pair.base), rawSettings: source.rawSettings,
            texture: pair.base, baseSpace: Self.workingColorSpace, gainTexture: source.gainTexture)
        target.samplingRegion = CGRect(x: region.minX / Double(size.width), y: region.minY / Double(size.height),
                                       width: region.width / Double(size.width), height: region.height / Double(size.height))
        target.gainSamplingRegion = source.gainSamplingRegion
        target.geometryUncroppedSize = source.geometryUncroppedSize
        return (target, hdr)
    }

    private func encodeDisplayHDR(_ pair: DisplayGainPair, into command: any MTLCommandBuffer) throws -> any MTLTexture {
        let node = nodeContext(domain: .dual, buffer: command)
        let output = try node.texture(width: pair.base.width, height: pair.base.height)
        var p = DisplayHDRUniform(p3ToGain: pair.p3ToGain, gainToP3: pair.gainToP3,
            baseOffset: SIMD4(pair.baseOffset, 0), alternateOffset: SIMD4(pair.alternateOffset, 0),
            channels: SIMD4(UInt32(pair.gainChannelCount), 0, 0, 0))
        try node.dispatch("displayHDR", width: output.width, height: output.height,
            textures: [pair.base, pair.gain, output], value: &p)
        return output
    }

    /// Normalize a rendered pair for display, retaining the export pair unchanged.
    /// `source` supplies the system HDR reconstruction for legacy Apple metadata.
    public func displayPair(_ planes: RenderPlanes, source: RenderSource) throws -> DisplayGainPair {
        try normalizedDisplayPair(planes, source: source, into: nil)
    }

    /// Export already scans the complete image for its header. Encode only the
    /// pair conversion into the consumer's command, without a local peak/readback.
    /// The returned headroom is declarative; callers needing an untagged measured
    /// headroom must use displayPair for that first header-bearing band.
    func encodeExportDisplayPair(_ planes: RenderPlanes, source: RenderSource,
                                 into command: any MTLCommandBuffer) throws -> DisplayGainPair {
        try normalizedDisplayPair(planes, source: source, into: command)
    }

    private func normalizedDisplayPair(_ planes: RenderPlanes, source: RenderSource,
                                       into consumer: (any MTLCommandBuffer)?) throws -> DisplayGainPair {
        try Task.checkCancellation()
        let measuresPeak = consumer == nil
        var baseOffset = SIMD3<Float>.zero, alternateOffset = SIMD3<Float>.zero
        var baseHeadroom: Float = 0, taggedHeadroom: Float?
        var gainSpace = Self.workingColorSpace
        var iso: AuthoredGainMap?
        var legacy = false
        switch planes.encoding {
        case .log2: break
        case .pairedLog2(let offset, let headroom):
            baseOffset = SIMD3(repeating: offset); alternateOffset = baseOffset
            taggedHeadroom = headroom
        case .isoLog2(let metadata):
            gainSpace = metadata.workingColorSpace
            baseOffset = metadata.baseOffset; alternateOffset = metadata.alternateOffset
            baseHeadroom = Float(metadata.source.baseHeadroom ?? 0)
            taggedHeadroom = metadata.source.alternateHeadroom.map(Float.init)
            if taggedHeadroom == nil && metadata.source.standard == .apple && source.hdrImage.contentHeadroom > 1 {
                taggedHeadroom = log2(source.hdrImage.contentHeadroom)
            }
        case .authored(let metadata):
            gainSpace = metadata.gainWorkingColorSpace ?? planes.baseColorSpace
            baseHeadroom = Float(metadata.baseHeadroom ?? 0)
            taggedHeadroom = metadata.alternateHeadroom.map(Float.init)
            if let channels = metadata.isoChannels {
                iso = metadata
                func vector(_ key: KeyPath<ISOGainChannel,Double>) -> SIMD3<Float> {
                    SIMD3((0..<3).map { Float(channels[channels.count == 1 ? 0 : $0][keyPath:key]) })
                }
                baseOffset = vector(\.baseOffset); alternateOffset = vector(\.alternateOffset)
            } else {
                // Legacy encoding is delegated to the system decoder. Invert its
                // full HDR per channel into an equivalent ISO pair, never a luma ratio.
                legacy = true
                baseOffset = SIMD3(repeating:1/64); alternateOffset = baseOffset
            }
        }
        let gainToP3 = try displayMatrixToP3(gainSpace)
        let p3ToGain = simd_inverse(gainToP3)
        let baseMatrix = try displayMatrixToP3(planes.baseColorSpace)
        guard let command = consumer ?? queue.makeCommandBuffer(),
              let peak = device.makeBuffer(length:MemoryLayout<UInt32>.size,options:.storageModeShared) else {
            throw RenderError.allocationFailed
        }
        peak.contents().storeBytes(of:UInt32(0),as:UInt32.self)
        let node = nodeContext(domain:source.domain,buffer:command)
        let base: any MTLTexture
        if baseMatrix == matrix_identity_float3x3 { base = planes.base }
        else {
            base = try node.texture(width:planes.base.width,height:planes.base.height)
            var matrix = baseMatrix
            try node.dispatch("displayBase",width:base.width,height:base.height,textures:[planes.base,base],value:&matrix)
        }
        let gain: any MTLTexture
        let count: Int
        if let iso, let channels = iso.isoChannels {
            count = max(planes.gainChannelCount,channels.count)
            // ISO/Apple decode the filtered encoded samples, not filtered log2
            // samples. Keep native gain coordinates for whole, resized and ROI.
            let encoded = source.gainTexture ?? planes.gain
            gain = try node.texture(width:base.width,height:base.height,
                                    format:count == 1 ? .r32Float : .rgba32Float)
            func vector(_ key: KeyPath<ISOGainChannel,Double>) -> SIMD4<Float> {
                SIMD4(Float(channels[0][keyPath:key]),Float(channels[channels.count == 1 ? 0 : 1][keyPath:key]),
                      Float(channels[channels.count == 1 ? 0 : 2][keyPath:key]),0)
            }
            var p = DisplayISOUniform(minimum:vector(\.minimum),maximum:vector(\.maximum),
                inverseGamma:1/vector(\.gamma),channels:SIMD4(UInt32(planes.gainChannelCount),measuresPeak ? 1 : 0,0,0),
                output:SIMD4(UInt32(planes.outputSize.width),UInt32(planes.outputSize.height),UInt32(planes.region.minX),UInt32(planes.region.minY)),
                sourceRegion:sourceSampling(encoded,source.gainSamplingRegion))
            try node.dispatch("displayISOGain",width:gain.width,height:gain.height,
                              textures:[encoded,gain],buffers:[peak],value:&p)
        } else if legacy {
            let working = try authorWorking(source)
            count = 3
            gain = try node.texture(width:base.width,height:base.height)
            // Match a cropped preview or detail region against the original source.
            var p = DisplayLegacyUniform(gainToP3:gainToP3,baseOffset:SIMD4(baseOffset,0),alternateOffset:SIMD4(alternateOffset,0),
                region:SIMD4(Float(planes.region.minX),Float(planes.region.minY),Float(planes.region.width),Float(planes.region.height)),
                size:SIMD4(Float(planes.outputSize.width),Float(planes.outputSize.height),measuresPeak ? 1 : 0,0),inputRegion:sourceSampling(source.texture,source.samplingRegion))
            try node.dispatch("displayLegacyGain",width:gain.width,height:gain.height,
                              textures:[working.base,working.hdr,gain],buffers:[peak],value:&p)
        } else {
            count = planes.gainChannelCount; gain = planes.gain
            if measuresPeak {
                var channels = UInt32(count)
                try node.dispatch("displayGainPeak",width:gain.width,height:gain.height,
                                  textures:[gain],buffers:[peak],value:&channels)
            }
        }
        if measuresPeak { try finish(command) }
        let measuredHeadroom = measuresPeak ? Float(bitPattern:peak.contents().load(as:UInt32.self)) : 0
        let alternateHeadroom = taggedHeadroom ?? max(measuredHeadroom, legacy ? log2(max(1,source.hdrImage.contentHeadroom)) : 0)
        return DisplayGainPair(base:base,gain:gain,gainChannelCount:count,baseOffset:baseOffset,alternateOffset:alternateOffset,
            baseHeadroom:baseHeadroom,alternateHeadroom:alternateHeadroom,p3ToGain:p3ToGain,gainToP3:gainToP3,region:planes.region,outputSize:planes.outputSize)
    }

    /// Core Image/ColorSync resolves the ICC chromatic adaptation and primaries.
    /// Three linear basis colors give the columns of the native-linear -> P3 matrix.
    func displayMatrixToP3(_ space: CGColorSpace) throws -> simd_float3x3 {
        if CFEqual(space,Self.workingColorSpace) || space.model == .monochrome { return matrix_identity_float3x3 }
        if let cached = displayMatrices.first(where:{ CFEqual($0.space,space) }) { return cached.matrix }
        guard space.model == .rgb else { throw RenderError.unsupportedGainColorSpace }
        let basis: [SIMD4<Float>] = [SIMD4(1,0,0,1),SIMD4(0,1,0,1),SIMD4(0,0,1,1)]
        let image = CIImage(bitmapData:basis.withUnsafeBytes { Data($0) },bytesPerRow:48,
                            size:CGSize(width:3,height:1),format:.RGBAf,colorSpace:space)
        let converted = Self.readTexture(try rasterize(image,space:Self.workingColorSpace))
        let matrix = simd_float3x3(columns:(SIMD3(converted[0],converted[1],converted[2]),
            SIMD3(converted[4],converted[5],converted[6]),SIMD3(converted[8],converted[9],converted[10])))
        displayMatrices.append((space,matrix))
        return matrix
    }
}
