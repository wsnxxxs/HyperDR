import CoreImage
import Foundation
import Metal

/// The Apple display development of a RAW, staged for a scene look.
///
/// Film and SDR-output Log looks preserve captured HDR from Apple's display
/// development at every strength; partial looks also crossfade to it. An
/// export reading bands would otherwise open the RAW again for every band,
/// each time with its own native decoder storage beside the scene-linear
/// graph's. Staging develops the whole endpoint once, in the canonical native
/// cells of `rasterizeNativeRAW`, into an anonymous float32 file, and releases
/// that decoder before the scene-linear graph opens. Bands read their window
/// back from the file. The cells are the ones a band would have developed, so
/// the pixels are the same; only one native decoder is alive at a time.
final class StagedLookBaseline: @unchecked Sendable {
    let spool: RAWExportSpool
    /// The Apple development's integral extent, in Core Image coordinates.
    let bounds: CGRect

    init(spool: RAWExportSpool, bounds: CGRect) {
        self.spool = spool
        self.bounds = bounds
    }

    /// The staged pixels of `region` (Core Image coordinates inside `bounds`)
    /// as a top-down working-space texture, like `rasterizeNativeRAW` returns.
    func texture(region: CGRect, context: RenderNodeContext) throws -> any MTLTexture {
        let region = region.integral
        guard bounds.contains(region) else { throw RenderError.invalidRegion }
        let top = CGRect(x: region.minX - bounds.minX, y: bounds.maxY - region.maxY,
                         width: region.width, height: region.height)
        let pixels = try spool.read(region: top)
        let width = Int(region.width), height = Int(region.height)
        let texture = try context.texture(width: width, height: height)
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * RAWExportSpool.bytesPerPixel)
        }
        return texture
    }
}

extension RenderEngine {
    /// Develops Apple's display endpoint of `url` (the scene-linear `options`
    /// with Apple's development) into a staged file, one canonical cell at a
    /// time. The file's space is reserved before the first cell develops; the
    /// RAW graph and its decoder caches are released before this returns.
    func stageLookBaseline(_ url: URL, options: SourceOptions, revision: SourceRevision,
                           allowsFallback: Bool) async throws -> (staged: StagedLookBaseline?, options: SourceOptions) {
        var options = options
        options.sceneLinear = false
        options.resolution = .full
        let result = try await Self.openWithCompatibility(url, options: options, deferred: true,
            allowsFallback: allowsFallback, retryNativeDecoder: false, revision: revision)
        options = result.options
        guard result.opened.domain == .rawEDR else { return (nil, options) }
        let staged = try autoreleasepool { () throws -> StagedLookBaseline in
            let opened = result.opened
            let bounds = opened.image.extent.integral
            let size = PixelSize(width: Int(bounds.width), height: Int(bounds.height))
            try validate(size)
            let cell = Self.nativeRAWCellSize
            let spool: RAWExportSpool
            do { spool = try RAWExportSpool(size: size, cellSize: cell) }
            catch ExportSpoolError.insufficientSpace(let required, let available) {
                throw RenderError.insufficientStorage(required: Int64(clamping: required), available: Int64(clamping: available))
            }
            for top in stride(from: 0, to: size.height, by: cell.height) {
                let rows = min(cell.height, size.height - top)
                for left in stride(from: 0, to: size.width, by: cell.width) {
                    let columns = min(cell.width, size.width - left)
                    try autoreleasepool {
                        let region = CGRect(x: bounds.minX + Double(left), y: bounds.maxY - Double(top + rows),
                                            width: Double(columns), height: Double(rows))
                        let texture = try rasterizeNativeRAW(opened.image, region: region, space: Self.workingColorSpace)
                        var pixels = [Float](repeating: 0, count: columns * rows * 4)
                        pixels.withUnsafeMutableBytes {
                            texture.getBytes($0.baseAddress!, bytesPerRow: columns * RAWExportSpool.bytesPerPixel,
                                             from: MTLRegionMake2D(0, 0, columns, rows), mipmapLevel: 0)
                        }
                        try spool.append(pixels, region: CGRect(x: left, y: top, width: columns, height: rows))
                    }
                }
            }
            try spool.seal()
            return StagedLookBaseline(spool: spool, bounds: bounds)
        }
        clearImageCaches()
        try revision.validate(url)
        return (staged, options)
    }
}
