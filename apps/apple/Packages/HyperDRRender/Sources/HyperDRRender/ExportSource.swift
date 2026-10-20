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

/// System decode/development source. No full-size RGBAf texture is allocated
/// by Render. Large TIFFs retain one detached native bitmap for ROI reuse;
/// other Apple codecs/CIRAWFilter may still cache full-frame data internally.
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
    /// Opens full-quality system graphs/native decoder storage and materializes
    /// only the fixed analysis texture. Drops pixel caches, retaining four AI grids.
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
    public func materializeExportRegion(_ source: ExportSource, outputSize: PixelSize, region: CGRect) throws -> RenderSource {
        try Task.checkCancellation()
        try source.revision.validate(source.url)
        _ = try validatedRegion(region, size:outputSize)
        let full = source.nativeSize
        let sx = Double(full.width)/Double(outputSize.width), sy = Double(full.height)/Double(outputSize.height)
        // Bound the texel centers actually sampled, rather than a whole source
        // pixel footprint for a 1-pixel panorama downscale.
        let projected = CGRect(x:(region.minX+0.5)*sx-0.5,y:(region.minY+0.5)*sy-0.5,
            width:(region.width-1)*sx+1,height:(region.height-1)*sy+1)
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
        let base = try rasterize(baseImage,space:opened.baseSpace,maximumRows:PreparedExportRows.maximumSourceTileSize.height)
        var gainTexture: (any MTLTexture)?, gainRegion = CGRect(x:0,y:0,width:1,height:1)
        if let gain = opened.gain {
            let size = gain.image.extent.integral.size
            // Project independently: the base ROI already includes its own halo.
            // Reusing it here would add the gain halo to the base halo.
            let gx = size.width/Double(outputSize.width), gy = size.height/Double(outputSize.height)
            let rect = CGRect(x:(region.minX+0.5)*gx-0.5,y:(region.minY+0.5)*gy-0.5,
                width:(region.width-1)*gx+1,height:(region.height-1)*gy+1)
                .insetBy(dx:-1,dy:-1).integral.intersection(CGRect(origin:.zero,size:size))
            gainRegion = CGRect(x:rect.minX/size.width,y:rect.minY/size.height,width:rect.width/size.width,height:rect.height/size.height)
            gainTexture = try rasterize(crop(gain.image,normalized:gainRegion),space:nil,
                                        format:gain.channelCount == 1 ? .r32Float : .rgba32Float,maximumRows:PreparedExportRows.maximumSourceTileSize.height)
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
