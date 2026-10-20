import Foundation
import CoreImage
import Metal

/// The whole AI gain step in one call: analysis size, feature planes, prediction.
extension ModelGainModel {
    /// `sourceSize` is the base's pixel size; the analysis grid is derived from it
    /// the way the engine derives it (`ModelGain.tensorSize`).
    public func gain(from image: CIImage, context: CIContext, sourceSize: PixelSize,
                     longSide: Int = ModelGain.analysisLongSide) throws -> ModelGainGrid {
        let tensorSize = ModelGain.tensorSize(for: sourceSize, longSide: longSide)
        return try gain(for: ModelGainInput.features(from: image, context: context,
                                                     tensorSize: tensorSize))
    }
}

/// Turns a linear Display-P3 base into the AI gain model's input tensor.
///
/// Inference happens once per photograph at a fixed analysis scale, not per
/// frame, so this path favours being obviously correct over being clever: one GPU
/// render to the analysis size, then the feature planes on the CPU. At the
/// default scale (long side 1024) that is under a megapixel of work.
///
/// Textures in this package are top-down, and the planes are built and returned
/// top-down, so the grid reaches the graph in the same row order as the base.
public enum ModelGainInput {
    /// Rasterizes `image` at `tensorSize` and builds the five feature planes.
    ///
    /// `image` must already carry the source orientation and be in the working
    /// space (linear extended Display P3), which is what `RenderSource` exposes.
    public static func features(from image: CIImage, context: CIContext,
                                tensorSize: PixelSize,
                                workingSpace: CGColorSpace = RenderEngine.workingColorSpace) throws -> ModelGainFeatures {
        let rgb = try rasterize(image, context: context, size: tensorSize, workingSpace: workingSpace)
        return try ModelGainFeatures.make(linearP3RGB: rgb, size: tensorSize)
    }

    /// Same, for a base plane that is already a texture.
    ///
    /// The texture is interpreted with this package's contract: RGBA, linear
    /// Display P3, top-down rows. Only the first three channels are read. Core
    /// Image reads a texture's first row as the bottom of the image, so the single
    /// flip below is what puts the picture back the right way up.
    public static func features(from texture: any MTLTexture, context: CIContext,
                                tensorSize: PixelSize,
                                workingSpace: CGColorSpace = RenderEngine.workingColorSpace) throws -> ModelGainFeatures {
        let height = CGFloat(texture.height)
        guard var image = CIImage(mtlTexture: texture, options: [.colorSpace: workingSpace]) else {
            throw ModelGainError.predictionFailed("the texture is not readable as an image")
        }
        image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))
        return try features(from: image, context: context, tensorSize: tensorSize, workingSpace: workingSpace)
    }

    /// Renders `image` into `size` and returns interleaved RGB floats, top-down.
    ///
    /// A bitmap destination is used rather than a texture because its row order is
    /// the one this package publishes (`CIContext.render(_:toBitmap:)` writes the
    /// image's top row first), so no flip is needed and no device has to be
    /// guessed. The scaling itself still happens on the GPU.
    private static func rasterize(_ image: CIImage, context: CIContext, size: PixelSize,
                                  workingSpace: CGColorSpace) throws -> [Float] {
        guard size.width > 0, size.height > 0,
              size.width % ModelGain.stride == 0, size.height % ModelGain.stride == 0 else {
            throw ModelGainError.invalidTensorSize(size)
        }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.isInfinite == false else {
            throw ModelGainError.predictionFailed("the base image has no finite extent")
        }
        // One affine scale to the analysis size. The analysis size is derived from
        // the source size with the same stride alignment, so this introduces no
        // aspect change beyond the engine's own rounding.
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: CGFloat(size.width) / extent.width,
                                               y: CGFloat(size.height) / extent.height))
            .transformed(by: CGAffineTransform(translationX: -extent.minX * CGFloat(size.width) / extent.width,
                                               y: -extent.minY * CGFloat(size.height) / extent.height))
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var rgba = [Float](repeating: 0, count: size.width * size.height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(scaled, toBitmap: bytes.baseAddress!, rowBytes: size.width * 4 * 4,
                           bounds: bounds, format: .RGBAf, colorSpace: workingSpace)
        }
        var rgb = [Float](repeating: 0, count: size.width * size.height * 3)
        for index in 0..<(size.width * size.height) {
            rgb[index * 3] = rgba[index * 4]
            rgb[index * 3 + 1] = rgba[index * 4 + 1]
            rgb[index * 3 + 2] = rgba[index * 4 + 2]
        }
        return rgb
    }
}
