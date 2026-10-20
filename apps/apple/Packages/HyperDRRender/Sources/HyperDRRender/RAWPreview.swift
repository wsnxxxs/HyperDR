import Foundation
import CoreImage
import Metal

extension RenderEngine {
    /// Develop native RAW ROIs before downsampling. A reduced CIRAWFilter graph
    /// can allocate native-area float intermediates even for a tiny destination.
    /// Reuse the export's native tile envelope without reducing working precision.
    func rasterizeRAWPreview(_ image: CIImage, size: PixelSize, space: CGColorSpace) throws -> any MTLTexture {
        try validate(size)
        let bounds = image.extent.integral
        let sx = bounds.width/Double(size.width), sy = bounds.height/Double(size.height)
        let limit = PreparedExportRows.maximumSourceTileSize
        let columns = max(1,Int(Double(limit.width-6)/sx))
        let rows = max(1,Int(Double(limit.height-6)/sy))
        guard let allocation = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let output = try nodeContext(domain:.rawEDR,buffer:allocation).texture(width:size.width,height:size.height)
        for y in stride(from:0,to:size.height,by:rows) {
            for x in stride(from:0,to:size.width,by:columns) {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let width = min(columns,size.width-x), height = min(rows,size.height-y)
                    let pixels = CGRect(x:(Double(x)+0.5)*sx-0.5,y:(Double(y)+0.5)*sy-0.5,
                        width:Double(width-1)*sx+1,height:Double(height-1)*sy+1)
                        .insetBy(dx:-2,dy:-2).integral.intersection(CGRect(origin:.zero,size:bounds.size))
                    let crop = CGRect(x:bounds.minX+pixels.minX,y:bounds.maxY-pixels.maxY,
                                      width:pixels.width,height:pixels.height)
                    let source = try rasterize(image.cropped(to:crop),space:space,maximumRows:limit.height)
                    guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
                    let node = nodeContext(domain:.rawEDR,buffer:command)
                    let tile = try node.texture(width:width,height:height)
                    var sampling = SourceSampling(width:UInt32(size.width),height:UInt32(size.height),x:UInt32(x),y:UInt32(y),
                        sourceRegion:SIMD4(Float(pixels.minX),Float(pixels.minY),Float(bounds.width),Float(bounds.height)))
                    try node.dispatch("sampleSource",width:width,height:height,textures:[source,tile],value:&sampling)
                    guard let blit = command.makeBlitCommandEncoder() else { throw RenderError.allocationFailed }
                    blit.copy(from:tile,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                        sourceSize:MTLSize(width:width,height:height,depth:1),to:output,destinationSlice:0,
                        destinationLevel:0,destinationOrigin:MTLOrigin(x:x,y:y,z:0))
                    blit.endEncoding()
                    try finish(command)
                }
            }
        }
        return output
    }
}
