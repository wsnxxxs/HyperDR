import CoreImage
import Foundation
import Metal

/// P7-0 stand-in for HyperDRRender's source node: the photo's original bytes
/// read by Core Image as HDR (`expandToHDR` applies a gain map; HLG and PQ
/// photos are HDR already), upright, and rendered for the canvas at the
/// display's headroom. Once HyperDRRender lands, its source node replaces this
/// file and the canvas draws Render's output instead.
nonisolated struct HDRPhoto: @unchecked Sendable {
    /// Upright, extent at the origin, at most `TemporaryHDRSource.maxLongEdge`.
    let image: CIImage
    /// Pixels of `image`, the canvas's image size.
    let size: CGSize
    /// The brightest value the photo holds, relative to SDR white (1 for SDR).
    let headroom: CGFloat
}

nonisolated enum TemporaryHDRSource {
    /// The canvas texture is rgba16Float with mips; 4096 px keeps it near
    /// 130 MB. Full-resolution tiling is Render's job.
    static let maxLongEdge: CGFloat = 4096

    enum Failure: Error { case unreadable }

    static func load(_ data: Data) throws -> HDRPhoto {
        guard var image = CIImage(data: data, options: [.expandToHDR: true, .applyOrientationProperty: true]) else {
            throw Failure.unreadable
        }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else {
            throw Failure.unreadable
        }
        let headroom = CGFloat(max(1, image.contentHeadroom))
        let scale = min(1, maxLongEdge / max(extent.width, extent.height))
        if scale < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // Whole pixels inside the scaled image, so no edge texel is left empty.
        let size = CGSize(width: max(1, image.extent.width.rounded(.down)), height: max(1, image.extent.height.rounded(.down)))
        // Decoded once; re-rendering for a new display headroom starts here.
        image = image.cropped(to: CGRect(origin: .zero, size: size)).insertingIntermediate(cache: true)
        return HDRPhoto(image: image, size: size, headroom: headroom)
    }

    /// Core Image context for `render`: half-float working format, so values
    /// above SDR white survive to the canvas.
    static func makeContext(queue: any MTLCommandQueue) -> CIContext {
        CIContext(mtlCommandQueue: queue, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
    }

    /// The canvas texture for `photo` on a display that can show `displayHeadroom`
    /// right now: brighter highlights are tone mapped down to it rather than
    /// clipped. Blocks until the GPU is done; call off the main thread.
    static func render(_ photo: HDRPhoto, displayHeadroom: CGFloat, context: CIContext,
                       queue: any MTLCommandQueue) throws -> any MTLTexture {
        let texture = try EDRDisplayPass.intermediateTexture(device: queue.device,
            width: Int(photo.size.width), height: Int(photo.size.height),
            usage: [.shaderRead, .shaderWrite, .renderTarget])
        var image = photo.image
        let target = max(1, displayHeadroom)
        if photo.headroom > target {
            image = image.applyingFilter("CIToneMapHeadroom", parameters: [
                "inputSourceHeadroom": Float(photo.headroom), "inputTargetHeadroom": Float(target)])
        }
        // Core Image writes its bottom row to texel row 0; the display pass
        // samples row 0 as the top of the photo.
        image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: photo.size.height))
        guard let command = queue.makeCommandBuffer(),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw PreviewError.unavailable("Unable to make a Metal command buffer")
        }
        context.render(image, to: texture, commandBuffer: command,
                       bounds: CGRect(origin: .zero, size: photo.size), colorSpace: space)
        if let blit = command.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        return texture
    }
}
