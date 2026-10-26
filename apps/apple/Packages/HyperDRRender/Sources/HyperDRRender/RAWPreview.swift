import Foundation
import CoreImage
import Metal

private struct RAWAreaSampling {
    // Output/native sizes in xy, tile origins in zw; per-kernel controls in options.
    var output, source, options: SIMD4<UInt32>
}

extension RenderEngine {
    /// Rasterize the reduced CIRAWFilter graph at the exact preview grid. Only
    /// temporary editable previews use this; native development stays below.
    func rasterizeDraftRAWPreview(_ image: CIImage, size: PixelSize, space: CGColorSpace) throws -> any MTLTexture {
        try validate(size)
        // On macOS 15.5 a reduced RAW graph transformed directly into a Metal
        // destination can return opaque black tiles (Canon CR2 -> 8.dng).
        // Materialize bounded RGBAf bitmap cells before our own area sampling,
        // as for the final preview. Keep the reduced demosaic for fast opening;
        // never attach the final resize/vertical flip to the lazy RAW graph.
        return try rasterizeRAWPreviews(image, sizes: [size], space: space)[0]
    }

    /// Decode each canonical native cell once, then integrate its owned pixels
    /// independently into each requested area grid. No output is resampled from another.
    func rasterizeRAWPreviews(_ image: CIImage, sizes: [PixelSize], space: CGColorSpace) throws -> [any MTLTexture] {
        for size in sizes { try validate(size) }
        let bounds = image.extent.integral
        guard bounds.width > 0, bounds.height > 0,
              bounds.width <= Double(UInt32.max), bounds.height <= Double(UInt32.max) else { throw RenderError.invalidSize }
        guard let clear = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let node = nodeContext(domain: .rawEDR, buffer: clear)
        let outputs = try sizes.map { try node.texture(width: $0.width, height: $0.height) }
        for output in outputs {
            var unused: UInt32 = 0
            try node.dispatch("zeroGain", width: output.width, height: output.height, textures: [output], value: &unused)
        }
        try finish(clear)
        let columns = Self.nativeRAWCellSize.width, rows = Self.nativeRAWCellSize.height
        for y in stride(from: 0, to: Int(bounds.height), by: rows) {
            for x in stride(from: 0, to: Int(bounds.width), by: columns) {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let width = min(columns, Int(bounds.width) - x), height = min(rows, Int(bounds.height) - y)
                    let inner = CGRect(x: bounds.minX + CGFloat(x), y: bounds.maxY - CGFloat(y + height),
                                       width: CGFloat(width), height: CGFloat(height))
                    // Identical rectangle, halo and whole-inner validation to rasterizeNativeRAW.
                    let decode = inner.insetBy(dx: -2, dy: -2).intersection(bounds)
                    let owned = CGRect(x: inner.minX - decode.minX, y: decode.maxY - inner.maxY,
                                       width: CGFloat(width), height: CGFloat(height))
                    var source: (any MTLTexture)?
                    for _ in 0..<Self.decodeAttempts {
                        let candidate = try rasterizeRAWBitmap(image, region: decode, space: space)
                        if try transparentTexels(candidate, region: owned) == 0 {
                            source = candidate
                            break
                        }
                    }
                    guard let source else { throw RenderError.cannotDecodeSource }
                    guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
                    let node = nodeContext(domain: .rawEDR, buffer: command)
                    for (size, output) in zip(sizes, outputs) {
                        // Include a one-pixel guard for float boundary rounding in the kernel.
                        let firstX = max(0, Int(floor(Double(x) * Double(size.width) / bounds.width)) - 1)
                        let firstY = max(0, Int(floor(Double(y) * Double(size.height) / bounds.height)) - 1)
                        let lastX = min(size.width, Int(ceil(Double(x + width) * Double(size.width) / bounds.width)) + 1)
                        let lastY = min(size.height, Int(ceil(Double(y + height) * Double(size.height) / bounds.height)) + 1)
                        var sampling = RAWAreaSampling(
                            output: SIMD4(UInt32(size.width), UInt32(size.height), UInt32(firstX), UInt32(firstY)),
                            source: SIMD4(UInt32(bounds.width), UInt32(bounds.height), UInt32(x), UInt32(y)),
                            options: SIMD4(UInt32(width), UInt32(height), UInt32(owned.minX), UInt32(owned.minY)))
                        try node.dispatch("accumulateSourceArea", width: lastX - firstX, height: lastY - firstY,
                                          textures: [source, output], value: &sampling)
                    }
                    try finish(command)
                }
            }
        }
        return outputs
    }

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
                                let source = try rasterizeNativeRAW(image, region: crop, space: space)
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
