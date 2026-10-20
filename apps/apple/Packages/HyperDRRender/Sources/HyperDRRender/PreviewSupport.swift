import Foundation
import CoreImage
import Metal

extension RenderEngine {
    /// SDR-only thumbnail. Reads the base and never applies or mutates gain.
    /// Returned pixels are Display P3, top-to-bottom when drawn as a CGImage.
    public func sdrThumbnail(_ planes: RenderPlanes,
                             maximumSize: PixelSize = PixelSize(width:512,height:512)) throws -> CGImage {
        try Task.checkCancellation()
        guard maximumSize.width > 0, maximumSize.height > 0 else { throw RenderError.invalidSize }
        guard let image = CIImage(mtlTexture:planes.base,options:[.colorSpace:planes.baseColorSpace]) else {
            throw RenderError.cannotDecodeSource
        }
        // Public Metal textures have top-down rows; CI images have a bottom-left origin.
        let upright = image.transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:image.extent.height))
        let scale = min(1,Double(maximumSize.width)/image.extent.width,Double(maximumSize.height)/image.extent.height)
        let small = upright.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let bounds = CGRect(x:0,y:0,width:max(1,Int(small.extent.width.rounded(.down))),
                            height:max(1,Int(small.extent.height.rounded(.down))))
        guard let result = context.createCGImage(small,from:bounds,format:.RGBA8,
                                                 colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!) else {
            throw RenderError.cannotDecodeSource
        }
        try Task.checkCancellation()
        return result
    }
}
