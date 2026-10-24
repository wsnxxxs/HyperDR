import Foundation

/// The AI gain model's data contract, independent of Core ML.
///
/// The frozen research network (`research-cnn-v1`, 635k parameters) predicts a
/// signed log2 gain in stops on a stride-16 grid from five deterministic feature
/// planes of the linear-Display-P3 SDR base. This file holds the geometry and the
/// feature formula, so the values the model sees are one implementation rather
/// than a copy per call site.
///
/// The feature formula is the shipped engine's (`make_native_model_features` in
/// `modules/gainmap/src/native_model.cpp`), and the analysis geometry is the
/// engine's `make_native_model_input`: the long side is capped at
/// `analysisLongSide` and both axes are then rounded up to the 16-pixel stride.
/// Keeping it identical is what makes a Core ML prediction comparable with the
/// ncnn one; the tolerance gate in the tests compares the two directly.
public enum ModelGainError: Error, Sendable, Equatable {
    /// No compatible runtime device; distinct from a missing/corrupt model or prediction failure.
    case deviceUnavailable(String)
    /// This build carries no model: the weights are not in the repository, so
    /// an open-source build offers only the analytic expansion.
    case notIncluded
    case modelUnavailable(String)
    case invalidTensorSize(PixelSize)
    case invalidInputCount(expected: Int, actual: Int)
    case predictionFailed(String)
    case unexpectedGrid(expected: PixelSize, actual: PixelSize)
    /// The source kind cannot carry a model gain (authored HDR or a dual pair).
    case unsupportedSource(String)
}

public enum ModelGain {
    /// Every prediction cell covers 16 x 16 base pixels, and both base axes are
    /// multiples of this.
    public static let stride = 16
    /// The engine's `kDefaultNativeModelLongSide`. AI gain is inferred once per
    /// photograph at this analysis scale and cached, never per frame.
    public static let analysisLongSide = 1024
    /// File stem of the converted Core ML model inside the package resources.
    public static let modelName = "research-cnn-v1"
    /// Model version recorded by the conversion script; also embedded in the
    /// compiled model's metadata, which is what `ModelGainModel.version` reads.
    public static let modelVersion = "research-demo-fold0-seed908/v1"
    /// Where the model is looked up in the package resources.
    public static let resourceDirectory = "Models"

    /// The model file in `bundle`, compiled or as the package it was converted
    /// to, or nil when this build does not include it. Only looks: loading and
    /// compiling are `ModelGainModel`'s.
    public enum BundledModel: Sendable, Equatable {
        case compiled(URL)
        case package(URL)
    }

    public static func bundledModel(in bundle: Bundle? = nil) -> BundledModel? {
        let bundle = bundle ?? .module
        for directory in [resourceDirectory, nil] {
            if let url = bundle.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: directory) {
                return .compiled(url)
            }
            if let url = bundle.url(forResource: modelName, withExtension: "mlpackage", subdirectory: directory) {
                return .package(url)
            }
        }
        return nil
    }

    /// Whether this build includes the model. Cheap: nothing is loaded.
    public static var isIncluded: Bool { bundledModel() != nil }

    /// Bump when the feature formula or the input snapping changes: cached gains
    /// computed under the old contract must not be reused.
    public static let preprocessingRevision = "features-v1"

    /// Texture size for the model input, derived the way the engine derives it.
    ///
    /// The scale is capped at 1, so a photograph smaller than the analysis scale
    /// is never upsampled, and every result is a multiple of the stride.
    public static func tensorSize(for source: PixelSize, longSide: Int = analysisLongSide) -> PixelSize {
        let longest = max(source.width, source.height)
        guard source.width > 0, source.height > 0, longest > 0, longSide >= stride else {
            return PixelSize(width: stride, height: stride)
        }
        let scale = min(1, Double(longSide) / Double(longest))
        func aligned(_ value: Int) -> Int { max(stride, ((value + stride - 1) / stride) * stride) }
        let width = aligned(Int((Double(source.width) * scale).rounded()))
        let height = aligned(Int((Double(source.height) * scale).rounded()))
        return PixelSize(width: width, height: height)
    }

    /// Grid shape for a given model input size.
    public static func gridSize(for tensor: PixelSize) -> PixelSize {
        PixelSize(width: tensor.width / stride, height: tensor.height / stride)
    }
}

/// The five-channel input tensor, plane by plane.
///
/// Channels follow the model's `feature_contract`: linear Display-P3 red, green
/// and blue in [0, 1]; log luminance `clamp((log2(max(luma, 1e-6)) + 12) / 12,
/// 0, 1)`; and a clipping flag that is 1 where the brightest channel is at least
/// 0.98. Values are laid out plane-major and top-down, which is what Core ML's
/// NCHW multi-array wants for its first sample.
public struct ModelGainFeatures: Sendable, Equatable {
    public static let channelCount = 5
    public let size: PixelSize
    /// `channelCount * width * height` values, plane `p` at
    /// `p * width * height + y * width + x`.
    public let planes: [Float]

    public init(size: PixelSize, planes: [Float]) throws {
        let expected = Self.channelCount * size.width * size.height
        guard planes.count == expected else {
            throw ModelGainError.invalidInputCount(expected: expected, actual: planes.count)
        }
        self.size = size
        self.planes = planes
    }

    /// Builds the feature planes from an interleaved linear Display-P3 RGB image.
    ///
    /// `rgb` holds three channels per pixel, top-down, with relative SDR white at
    /// 1.0. Extended values are clamped into the model's [0, 1] contract, which is
    /// what the ncnn path also requires; a small negative from a gamut matrix is
    /// not an error, it is simply out of the model's declared domain.
    public static func make(linearP3RGB rgb: [Float], size: PixelSize) throws -> ModelGainFeatures {
        guard size.width > 0, size.height > 0,
              size.width % ModelGain.stride == 0, size.height % ModelGain.stride == 0 else {
            throw ModelGainError.invalidTensorSize(size)
        }
        let pixels = size.width * size.height
        guard rgb.count == pixels * 3 else {
            throw ModelGainError.invalidInputCount(expected: pixels * 3, actual: rgb.count)
        }
        // The same coefficients as the engine's p3_luminance caller.
        let lumaRed: Float = 0.22897456
        let lumaGreen: Float = 0.69173852
        let lumaBlue: Float = 0.07928691
        var planes = [Float](repeating: 0, count: pixels * ModelGainFeatures.channelCount)
        planes.withUnsafeMutableBufferPointer { output in
            rgb.withUnsafeBufferPointer { input in
                for index in 0..<pixels {
                    let red = min(max(input[index * 3], 0), 1)
                    let green = min(max(input[index * 3 + 1], 0), 1)
                    let blue = min(max(input[index * 3 + 2], 0), 1)
                    let luminance = max(0, lumaRed * red + lumaGreen * green + lumaBlue * blue)
                    let logged = min(max((log2(max(luminance, 1.0e-6)) + 12) / 12, 0), 1)
                    let clipping: Float = max(red, max(green, blue)) >= 0.98 ? 1 : 0
                    output[index] = red
                    output[pixels + index] = green
                    output[pixels * 2 + index] = blue
                    output[pixels * 3 + index] = logged
                    output[pixels * 4 + index] = clipping
                }
            }
        }
        return try ModelGainFeatures(size: size, planes: planes)
    }
}

/// The predicted gain field: signed log2 stops on the stride-16 grid.
///
/// Rows are top-down, matching plan textures. Every value is a stop count that
/// multiplies the SDR base: `HDR = base * 2^stops`. Downstream smoothing, the
/// strength and range controls and the ISO packaging all work on this grid; the
/// model itself only predicts it.
public struct ModelGainGrid: Sendable, Equatable {
    public let size: PixelSize
    public let log2Stops: [Float]

    public init(size: PixelSize, log2Stops: [Float]) {
        self.size = size
        self.log2Stops = log2Stops
    }

    public var maximumStops: Float { log2Stops.max() ?? 0 }
    public var minimumStops: Float { log2Stops.min() ?? 0 }
}
