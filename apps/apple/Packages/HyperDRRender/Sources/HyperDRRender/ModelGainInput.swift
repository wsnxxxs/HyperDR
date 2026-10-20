import Foundation
import CoreImage
import Metal

/// The whole AI gain step in one call: analysis size, feature planes, prediction.
extension ModelGainModel {
    /// `sourceSize` is the SDR base's pixel size; the analysis grid is derived from
    /// it the way the engine derives it (`ModelGain.tensorSize`).
    public func gain(from image: CIImage, context: CIContext, sourceSize: PixelSize,
                     longSide: Int = ModelGain.analysisLongSide,
                     device: (any MTLDevice)? = nil) throws -> ModelGainGrid {
        let tensorSize = ModelGain.tensorSize(for: sourceSize, longSide: longSide)
        return try gain(for: ModelGainInput.features(from: image, context: context,
                                                    tensorSize: tensorSize, device: device))
    }
}

/// Turns an SDR base into the AI gain model's input tensor.
///
/// Inference happens once per photograph at a fixed analysis scale, not per frame,
/// so this path favours being obviously correct over being clever: one GPU pass
/// reduces the base to the analysis size with the engine's equal-area filter
/// (`ModelGainResampler`), then the feature planes are built on the CPU. Textures
/// in this package are top-down, and the planes are built and returned top-down,
/// so the grid reaches the graph in the same row order as the base.
public enum ModelGainInput {
    /// Feature planes for a base that is already a texture (top-down, RGBA,
    /// linear Display P3). Nothing is read back at the base's own resolution: the
    /// resampler writes the analysis image and only that is read.
    public static func features(from texture: any MTLTexture, tensorSize: PixelSize,
                                device: (any MTLDevice)? = nil,
                                workingSpace: CGColorSpace = RenderEngine.workingColorSpace) throws -> ModelGainFeatures {
        let resampler = try resampler(for: device)
        let scaled = try resampler.resize(texture, to: tensorSize)
        return try features(fromRaster: scaled, size: tensorSize, workingSpace: workingSpace)
    }

    /// Feature planes for a Core Image base. The base is rendered and reduced a
    /// band of rows at a time, so a 61-megapixel source is never materialized whole.
    public static func features(from image: CIImage, context: CIContext, tensorSize: PixelSize,
                                device: (any MTLDevice)? = nil,
                                workingSpace: CGColorSpace = RenderEngine.workingColorSpace) throws -> ModelGainFeatures {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else {
            throw ModelGainError.predictionFailed("the base image has no finite extent")
        }
        let sourceSize = PixelSize(width: Int(extent.width.rounded()), height: Int(extent.height.rounded()))
        let resampler = try resampler(for: device)
        let scaled = try resampler.resize(image, context: context, sourceSize: sourceSize,
                                          to: tensorSize)
        return try features(fromRaster: scaled, size: tensorSize, workingSpace: workingSpace)
    }

    /// Analysis-size RGBA floats to the five planes. The analysis texture is small
    /// (about 11 MB at the default scale), so reading it back is cheap; the base is
    /// never read.
    private static func features(fromRaster texture: any MTLTexture, size: PixelSize,
                                 workingSpace: CGColorSpace) throws -> ModelGainFeatures {
        let rgba = RenderEngine.readTexture(texture)
        var rgb = [Float](repeating: 0, count: size.width * size.height * 3)
        for index in 0..<(size.width * size.height) {
            rgb[index * 3] = rgba[index * 4]
            rgb[index * 3 + 1] = rgba[index * 4 + 1]
            rgb[index * 3 + 2] = rgba[index * 4 + 2]
        }
        return try ModelGainFeatures.make(linearP3RGB: rgb, size: size)
    }

    /// One resampler per device: compiling the Metal kernel and creating a command
    /// queue per call would be wasteful, and the resampler keeps no state.
    private static func resampler(for device: (any MTLDevice)?) throws -> ModelGainResampler {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.metalUnavailable
        }
        let key = ObjectIdentifier(device)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = resamplers[key] { return cached }
        let created = try ModelGainResampler(device: device)
        resamplers[key] = created
        return created
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var resamplers: [ObjectIdentifier: ModelGainResampler] = [:]
}
