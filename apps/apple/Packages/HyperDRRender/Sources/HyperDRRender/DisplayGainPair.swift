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
}
private struct DisplaySampling { var width,height,x,y: UInt32 }
private struct DisplayLegacyUniform {
    var gainToP3: simd_float3x3
    var baseOffset, alternateOffset: SIMD4<Float>
    var region: SIMD4<Float>
    var size: SIMD4<Float>
}

extension RenderEngine {
    /// Normalize a rendered pair for display, retaining the export pair unchanged.
    /// `source` supplies the system HDR reconstruction for legacy Apple metadata.
    public func displayPair(_ planes: RenderPlanes, source: RenderSource) throws -> DisplayGainPair {
        try Task.checkCancellation()
        var baseOffset = SIMD3<Float>.zero, alternateOffset = SIMD3<Float>.zero
        var baseHeadroom: Float = 0, taggedHeadroom: Float?
        var gainSpace = Self.workingColorSpace
        var iso: AuthoredGainMap?
        var legacy = false
        switch planes.encoding {
        case .log2: break
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
        guard let command = queue.makeCommandBuffer(),
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
            // Decode before interpolation. A cropped/resized export pair contains
            // encoded samples; start from the native source gain for display.
            let encoded = source.gainTexture ?? planes.gain
            let decoded = try node.texture(width:encoded.width,height:encoded.height,
                                           format:count == 1 ? .r32Float : .rgba32Float)
            func vector(_ key: KeyPath<ISOGainChannel,Double>) -> SIMD4<Float> {
                SIMD4(Float(channels[0][keyPath:key]),Float(channels[channels.count == 1 ? 0 : 1][keyPath:key]),
                      Float(channels[channels.count == 1 ? 0 : 2][keyPath:key]),0)
            }
            var p = DisplayISOUniform(minimum:vector(\.minimum),maximum:vector(\.maximum),
                                      inverseGamma:1/vector(\.gamma),channels:SIMD4(UInt32(planes.gainChannelCount),0,0,0))
            try node.dispatch("displayISOGain",width:decoded.width,height:decoded.height,
                              textures:[encoded,decoded],buffers:[peak],value:&p)
            let bounds = CGRect(x:0,y:0,width:planes.outputSize.width,height:planes.outputSize.height)
            if planes.region == bounds && planes.outputSize == source.size { gain = decoded }
            else {
                gain = try node.texture(width:base.width,height:base.height,format:decoded.pixelFormat)
                var sampling = DisplaySampling(width:UInt32(planes.outputSize.width),height:UInt32(planes.outputSize.height),
                                               x:UInt32(planes.region.minX),y:UInt32(planes.region.minY))
                try node.dispatch("sampleSource",width:gain.width,height:gain.height,textures:[decoded,gain],value:&sampling)
            }
        } else if legacy {
            let working = try authorWorking(source)
            count = 3
            gain = try node.texture(width:base.width,height:base.height)
            // Match a cropped preview or detail region against the original source.
            var p = DisplayLegacyUniform(gainToP3:gainToP3,baseOffset:SIMD4(baseOffset,0),alternateOffset:SIMD4(alternateOffset,0),
                region:SIMD4(Float(planes.region.minX),Float(planes.region.minY),Float(planes.region.width),Float(planes.region.height)),
                size:SIMD4(Float(planes.outputSize.width),Float(planes.outputSize.height),0,0))
            try node.dispatch("displayLegacyGain",width:gain.width,height:gain.height,
                              textures:[working.base,working.hdr,gain],buffers:[peak],value:&p)
        } else {
            count = planes.gainChannelCount; gain = planes.gain
            var channels = UInt32(count)
            try node.dispatch("displayGainPeak",width:gain.width,height:gain.height,
                              textures:[gain],buffers:[peak],value:&channels)
        }
        try finish(command)
        let measuredHeadroom = Float(bitPattern:peak.contents().load(as:UInt32.self))
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
