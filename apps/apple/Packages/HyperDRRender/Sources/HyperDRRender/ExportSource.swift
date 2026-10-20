import Foundation
import CoreImage
import Metal
import HyperDRRecipe

struct SourceSampling {
    var width,height,x,y: UInt32
    var sourceRegion: SIMD4<Float>
}
// Native origin and full native dimensions, in pixels (not normalized UVs).
func sourceSampling(_ texture: any MTLTexture, _ region: CGRect) -> SIMD4<Float> {
    let width = (Double(texture.width)/region.width).rounded()
    let height = (Double(texture.height)/region.height).rounded()
    return SIMD4(Float((region.minX*width).rounded()),Float((region.minY*height).rounded()),Float(width),Float(height))
}

/// Lazy system decode/development graph. No full-size RGBAf texture is allocated
/// by Render. Apple codecs/CIRAWFilter may still cache full-frame data internally.
/// The caller must keep file access valid until export finishes. Immutable and may
/// be shared with another RenderEngine on the same Metal device.
public struct ExportSource: @unchecked Sendable {
    /// Same stable identity as load(.full) and preview for this revision/settings.
    public let id: UUID
    public let domain: InputDomain
    public let nativeSize: PixelSize
    public let rawSettings: RAWDevelopment?
    /// Fixed 1024-long-side source for analysis and predictModelGain; never full-size.
    public let analysisSource: RenderSource
    let opened: OpenedSource
    let url: URL
    let revision: SourceRevision
}

extension RenderEngine {
    /// Keeps full-quality system graphs lazy, and materializes only the fixed
    /// analysis source. Drops engine-owned pixel caches, retaining four AI grids.
    /// Use an export engine if the editor must keep its preview caches warm.
    public func openExportSource(_ url: URL, options: SourceOptions = SourceOptions()) throws -> ExportSource {
        try Task.checkCancellation()
        let revision = try SourceRevision(url:url)
        var fullOptions = options; fullOptions.resolution = .full
        let opened = try Self.open(url,options:fullOptions,deferred:true)
        let size = opened.nativeSize ?? opened.raw!.nativeSize
        try validate(size)
        let scale = min(1,1024/Double(max(size.width,size.height)))
        var analysisOptions = fullOptions
        analysisOptions.resolution = .preview(maximumSize:PixelSize(width:max(1,Int((Double(size.width)*scale).rounded(.up))),
                                                                    height:max(1,Int((Double(size.height)*scale).rounded(.up)))))
        clearImageCaches()
        let analysis = try load(url,options:analysisOptions)
        // This is exactly fixedAnalysisSource's 1024 policy; bind it directly
        // instead of constructing a second identical CIRAWFilter development.
        analysisSource = analysis
        try revision.validate(url)
        return ExportSource(id:analysis.id,domain:opened.domain,nativeSize:size,rawSettings:opened.raw,
                            analysisSource:analysis,opened:opened,url:url,revision:revision)
    }

    /// Materialize a native-pixel ROI plus two texels of sampling support. Decoder
    /// spatial filters receive the crop downstream, allowing Core Image to request
    /// their own input halo. Output coordinates remain global, not band-local.
    func materializeExportRegion(_ source: ExportSource, outputSize: PixelSize, region: CGRect) throws -> RenderSource {
        try Task.checkCancellation()
        try source.revision.validate(source.url)
        let full = source.nativeSize
        let projected = CGRect(x:region.minX*Double(full.width)/Double(outputSize.width),
            y:region.minY*Double(full.height)/Double(outputSize.height),
            width:region.width*Double(full.width)/Double(outputSize.width),
            height:region.height*Double(full.height)/Double(outputSize.height))
        let pixels = projected.insetBy(dx:-2,dy:-2).integral.intersection(CGRect(x:0,y:0,width:full.width,height:full.height))
        let normalized = CGRect(x:pixels.minX/Double(full.width),y:pixels.minY/Double(full.height),
                                width:pixels.width/Double(full.width),height:pixels.height/Double(full.height))
        func crop(_ image: CIImage, normalized: CGRect) -> CIImage {
            let bounds = image.extent.integral
            // Public normalized coordinates are top-down; Core Image is bottom-up.
            let rect = CGRect(x:bounds.minX+(normalized.minX*bounds.width).rounded(),
                y:bounds.minY+((1-normalized.maxY)*bounds.height).rounded(),
                width:(normalized.width*bounds.width).rounded(),height:(normalized.height*bounds.height).rounded())
            return image.cropped(to:rect.integral)
        }
        let opened = source.opened
        let baseImage = crop(opened.image,normalized:normalized), hdrImage = crop(opened.hdr,normalized:normalized)
        let base = try rasterize(baseImage,space:opened.baseSpace)
        var gainTexture: (any MTLTexture)?, gainRegion = CGRect(x:0,y:0,width:1,height:1)
        if let gain = opened.gain {
            let size = gain.image.extent.integral.size
            let rect = CGRect(x:normalized.minX*size.width,y:normalized.minY*size.height,
                width:normalized.width*size.width,height:normalized.height*size.height)
                .insetBy(dx:-1,dy:-1).integral.intersection(CGRect(origin:.zero,size:size))
            gainRegion = CGRect(x:rect.minX/size.width,y:rect.minY/size.height,width:rect.width/size.width,height:rect.height/size.height)
            gainTexture = try rasterize(crop(gain.image,normalized:gainRegion),space:nil,
                                        format:gain.channelCount == 1 ? .r32Float : .rgba32Float)
        }
        var result = RenderSource(id:source.id,renderID:UUID(),origin:source.analysisSource.origin,
            domain:source.domain,size:full,nativeSize:full,authoredGainMap:opened.gain,hdrImage:hdrImage,
            authoredBaseImage:opened.gain == nil ? nil : baseImage,rawSettings:opened.raw,
            texture:base,baseSpace:opened.baseSpace,gainTexture:gainTexture)
        result.samplingRegion = normalized; result.gainSamplingRegion = gainRegion
        try source.revision.validate(source.url)
        return result
    }
}
