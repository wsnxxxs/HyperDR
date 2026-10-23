import CoreImage
import Foundation
import Metal

extension RenderEngine {
    static let nativeRAWCellSize = PixelSize(width: 2044, height: 256)

    /// CIRAWFilter's float output can change with its requested rectangle, even
    /// at native resolution (the 61MP Sony RAW differs between 64- and 256-row
    /// requests). Decode fixed cells of the complete geometry-applied image,
    /// then copy the requested window. Each completed cell is released before
    /// developing the next; no cell is retained for a later read.
    func rasterizeNativeRAW(_ image: CIImage, region requested: CGRect? = nil,
                            space: CGColorSpace) throws -> any MTLTexture {
        try Task.checkCancellation()
        let bounds = image.extent.integral
        let region = (requested ?? bounds).integral
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width <= Double(UInt32.max), bounds.height <= Double(UInt32.max),
              region.width.isFinite, region.height.isFinite, region.minX.isFinite, region.minY.isFinite,
              !region.isEmpty, bounds.contains(region) else { throw RenderError.invalidRegion }
        try validate(PixelSize(width: Int(region.width), height: Int(region.height)))
        let halo = 2, columns = Self.nativeRAWCellSize.width, rows = Self.nativeRAWCellSize.height
        let left = Int(region.minX - bounds.minX), top = Int(bounds.maxY - region.maxY)
        let firstX = left / columns * columns, firstY = top / rows * rows
        var cells: [(inner: CGRect, decode: CGRect, copy: CGRect)] = []
        for y in stride(from: firstY, to: top + Int(region.height), by: rows) {
            for x in stride(from: firstX, to: left + Int(region.width), by: columns) {
                let inner = CGRect(x: bounds.minX + Double(x),
                    y: bounds.maxY - Double(min(y + rows, Int(bounds.height))),
                    width: Double(min(columns, Int(bounds.width) - x)),
                    height: Double(min(rows, Int(bounds.height) - y)))
                cells.append((inner, inner.insetBy(dx: -Double(halo), dy: -Double(halo)).intersection(bounds),
                    inner.intersection(region)))
            }
        }
        guard let allocation = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let output = try nodeContext(domain: .rawEDR, buffer: allocation)
            .texture(width: Int(region.width), height: Int(region.height))
        for cell in cells {
            try autoreleasepool {
                try Task.checkCancellation()
                // A retry always uses the identical canonical rectangle. An
                // adaptive split would reintroduce request-shape differences.
                for _ in 0..<Self.decodeAttempts {
                    let complete = try autoreleasepool { () throws -> Bool in
                        try Task.checkCancellation()
                        let texture = try rasterizeRAWBitmap(image, region: cell.decode, space: space)
                        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
                        // The fixed inner owns output. Validate it in full,
                        // including pixels outside this caller's window.
                        let inner = CGRect(x: cell.inner.minX - cell.decode.minX, y: cell.decode.maxY - cell.inner.maxY,
                            width: cell.inner.width, height: cell.inner.height)
                        let missing = try encodeTransparentCount(texture, region: inner, buffer: command)
                        try encodeNativeRAWCopy(texture, decode: cell.decode, copy: cell.copy, region: region,
                            output: output, command: command)
                        try finish(command)
                        if missing.contents().load(as: UInt32.self) == 0 {
                            return true
                        }
                        return false
                    }
                    if complete { return }
                }
                // Tentative copies are never published after an incomplete cell.
                throw RenderError.cannotDecodeSource
            }
        }
        return output
    }

    private func encodeNativeRAWCopy(_ texture: any MTLTexture, decode: CGRect, copy: CGRect, region: CGRect,
                                     output: any MTLTexture, command: any MTLCommandBuffer) throws {
        guard let blit = command.makeBlitCommandEncoder() else { throw RenderError.allocationFailed }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: Int(copy.minX - decode.minX), y: Int(decode.maxY - copy.maxY), z: 0),
            sourceSize: MTLSize(width: Int(copy.width), height: Int(copy.height), depth: 1),
            to: output, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: Int(copy.minX - region.minX), y: Int(region.maxY - copy.maxY), z: 0))
        blit.endEncoding()
    }
}
