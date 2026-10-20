import Foundation
import CoreImage
import Metal

private struct RAWAreaSampling {
    // Output/native sizes in xy, output/native tile origins in zw; options.x resets the sum.
    var output, source, options: SIMD4<UInt32>
}

extension RenderEngine {
    /// Develop native RAW ROIs before area downsampling. Include the entire
    /// footprint and a one-texel rounding guard, rather than sampling its center.
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
                    let width = min(columns,size.width-x), height = min(rows,size.height-y)
                    let pixels = CGRect(x:Double(x)*sx,y:Double(y)*sy,
                        width:Double(width)*sx,height:Double(height)*sy)
                        .insetBy(dx:-1,dy:-1).integral.intersection(CGRect(origin:.zero,size:bounds.size))
                    var accumulated: (any MTLTexture)?
                    // A single output pixel can cover more than the native tile
                    // envelope. Integrate bounded pieces without truncating it.
                    for ny in stride(from:0,to:Int(pixels.height),by:limit.height) {
                        for nx in stride(from:0,to:Int(pixels.width),by:limit.width) {
                            try autoreleasepool {
                                try Task.checkCancellation()
                                let nw = min(limit.width,Int(pixels.width)-nx)
                                let nh = min(limit.height,Int(pixels.height)-ny)
                                let native = CGRect(x:pixels.minX+Double(nx),y:pixels.minY+Double(ny),width:Double(nw),height:Double(nh))
                                let crop = CGRect(x:bounds.minX+native.minX,y:bounds.maxY-native.maxY,
                                                  width:native.width,height:native.height)
                                let source = try rasterize(image.cropped(to:crop),space:space,maximumRows:limit.height)
                                guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
                                let node = nodeContext(domain:.rawEDR,buffer:command)
                                let tile = try node.texture(width:width,height:height)
                                var sampling = RAWAreaSampling(
                                    output:SIMD4(UInt32(size.width),UInt32(size.height),UInt32(x),UInt32(y)),
                                    source:SIMD4(UInt32(bounds.width),UInt32(bounds.height),UInt32(native.minX),UInt32(native.minY)),
                                    options:SIMD4(accumulated == nil ? 1 : 0,0,0,0))
                                try node.dispatch("sampleSourceArea",width:width,height:height,
                                    textures:[source,accumulated ?? source,tile],value:&sampling)
                                if nx+nw == Int(pixels.width), ny+nh == Int(pixels.height) {
                                    guard let blit = command.makeBlitCommandEncoder() else { throw RenderError.allocationFailed }
                                    blit.copy(from:tile,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                                        sourceSize:MTLSize(width:width,height:height,depth:1),to:output,destinationSlice:0,
                                        destinationLevel:0,destinationOrigin:MTLOrigin(x:x,y:y,z:0))
                                    blit.endEncoding()
                                }
                                try finish(command)
                                accumulated = tile
                            }
                        }
                    }
                }
            }
        }
        return output
    }
}
