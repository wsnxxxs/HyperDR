import CoreImage
import Foundation
import HyperDRRecipe

public struct WhiteBalanceSample: Sendable {
    /// Recipe units: kelvin/RAW tint, or relative warmth/tint in percent.
    public let temperature: Double
    public let tint: Double
}

extension RenderEngine {
    /// Samples the unadjusted source. `point` is normalized, top-left, after
    /// `options.geometry`; geometry is inverted before the source is sampled.
    public func pickWhiteBalance(_ url: URL, options: SourceOptions, point: CGPoint,
                                 photoSize: PixelSize, raw: Bool) throws -> WhiteBalanceSample {
        let size = GeometrySize(width: Double(photoSize.width), height: Double(photoSize.height))
        let output = options.geometry.outputSize(of: size)
        let native = options.geometry.photoToOutput(for: size).inverse.apply(
            GeometryPoint(x: point.x * Double(output.width), y: point.y * Double(output.height)))
        if raw {
            var sampling = options
            sampling.resolution = .full
            sampling.draftRAWPreview = false
            let (filter, _, _, _) = try Self.configuredRAW(url, options: sampling)
            // neutralLocation uses oriented output pixels, bottom-left, at scaleFactor.
            // Always sample at scale 1 so the preview demosaic cannot move the pick.
            filter.neutralLocation = CGPoint(x: native.x, y: size.height - native.y)
            return WhiteBalanceSample(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
        }
        var sampling = options
        sampling.geometry = .identity
        sampling.resolution = .full
        let source = try Self.open(url, options: sampling, deferred: true)
        let image = source.image
        let x = min(image.extent.maxX - 1, max(0, native.x))
        let y = min(image.extent.maxY - 1, max(0, size.height - native.y))
        let region = CGRect(x: max(0, x - 2), y: max(0, y - 2), width: 5, height: 5).intersection(image.extent)
        let mean = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(mean, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: Self.workingColorSpace)
        return Self.neutralBalance(DoubleReference.RGB(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])))
    }

    /// Solve the two chroma differences using the same luminance-preserving
    /// operations as the graph (including each operation's neutral offset).
    static func neutralBalance(_ rgb: DoubleReference.RGB) -> WhiteBalanceSample {
        func residual(_ a: Double, _ b: Double) -> SIMD2<Double> {
            let warm = DoubleReference.point(rgb, operation: .warmth, value: a)
            let result = DoubleReference.point(warm, operation: .tint, value: b)
            return SIMD2(result.x - result.y, result.z - result.y)
        }
        var a = 0.0, b = 0.0
        for _ in 0..<10 {
            let r = residual(a, b)
            if max(abs(r.x), abs(r.y)) < 1e-8 { break }
            let da = (residual(a + 0.001, b) - r) / 0.001
            let db = (residual(a, b + 0.001) - r) / 0.001
            let determinant = da.x * db.y - db.x * da.y
            if abs(determinant) < 1e-14 { break }
            a -= (r.x * db.y - db.x * r.y) / determinant
            b -= (da.x * r.y - r.x * da.y) / determinant
        }
        return WhiteBalanceSample(temperature: a * 100, tint: b * 100)
    }
}
