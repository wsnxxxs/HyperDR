import CoreImage
import Metal
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension RenderEngine {
    /// The log2 brightness the film and LUT meters aim for. A RAW's embedded
    /// camera rendition carries the photographer's intent (exposure
    /// compensation, dynamic range settings, a backlit subject lifted), which
    /// Apple's unedited development does not, so it is the target when the
    /// file has one; anything else keeps `neutral`, the unedited development.
    /// Only this one number leaves the preview: its pixels never enter a render.
    /// A preview more than `previewAllowance` stops from the development is
    /// taken as unrelated to it (a placeholder, another crop) and ignored.
    func meterTarget(_ source: RenderSource,
                     readPreview: (URL) -> Double? = RenderEngine.cameraPreviewBrightness,
                     neutral: () throws -> Double) throws -> Double {
        let developed = try neutral()
        guard source.domain == .rawEDR, let origin = source.origin, !origin.options.rawEmbeddedPreview,
              let preview = readPreview(origin.url),
              Self.acceptsCameraPreview(preview, developed: developed) else { return developed }
        return preview
    }

    func smallMeterSource(_ original: RenderSource) throws -> RenderSource {
        let input = try workingInput(original)
        let image = CIImage(mtlTexture: input, options: [.colorSpace: Self.workingColorSpace])!
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(input.height)))
        let scale = min(1, 192 / Double(max(input.width, input.height)))
        let width = max(1, Int((Double(input.width) * scale).rounded()))
        let height = max(1, Int((Double(input.height) * scale).rounded()))
        let reduced = image.clampedToExtent().transformed(by: CGAffineTransform(
            scaleX: Double(width) / Double(input.width), y: Double(height) / Double(input.height)))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return try self.source(image: reduced, domain: original.domain == .dual ? .hdr : original.domain)
    }
    func meterBrightness(_ source: RenderSource, _ edit: RenderAdjustments, size: PixelSize? = nil) throws -> Double {
        let planes = try render(source, adjustments: edit, size: size)
        let input = planes.base
        guard let command = queue.makeCommandBuffer(),
              let rows = device.makeBuffer(length: input.width * input.height * 8, options: .storageModeShared)
        else { throw RenderError.allocationFailed }
        var unused: UInt32 = 0
        try nodeContext(domain: source.domain, buffer: command).dispatch("filmMeter",
            width: input.height, height: 1, textures: [input], buffers: [rows], value: &unused)
        try finish(command)
        let sums = UnsafeBufferPointer(start: rows.contents().bindMemory(to: SIMD2<Float>.self,
            capacity: input.width * input.height), count: input.width * input.height)
        let sorted = sums.sorted { $0.x < $1.x }
        let halfway = sorted.reduce(0.0) { $0 + Double($1.y) } / 2
        var weight = 0.0
        for sample in sorted {
            weight += Double(sample.y)
            if weight >= halfway { return Double(sample.x) }
        }
        return Double(sorted.last!.x)
    }

    static let previewAllowance = 2.5

    static func acceptsCameraPreview(_ preview: Double, developed: Double) -> Bool {
        preview.isFinite && developed.isFinite && abs(preview - developed) <= previewAllowance
    }

    /// Calibrate once for a newly opened RAW. The recorded result is a display
    /// development exposure; scene-linear film/Log input keeps its physical scale.
    /// Reduced drafts bound the work. Never use the camera JPEG as source pixels.
    public func cameraPreviewExposure(_ source: RenderSource) async throws -> Float? {
        guard source.domain == .rawEDR, let origin = source.origin,
              !origin.options.rawEmbeddedPreview,
              let target = Self.cameraPreviewBrightness(origin.url) else { return nil }
        var options = origin.options
        options.sceneLinear = false
        options.rawExposureBias = 0
        options.geometry = .identity
        options.resolution = .preview(maximumSize: PixelSize(width: 192, height: 192))
        options.draftRAWPreview = true
        let neutral = try await cameraDevelopmentBrightness(origin.url, options: options, exposure: 0)
        guard Self.acceptsCameraPreview(target, developed: neutral) else { return nil }
        var ev = 0.0, measured = neutral
        var bestEV = ev, bestError = abs(neutral - target)
        // A bracketed secant handles Apple's nonlinear boost curve. Stop at
        // 0.02 EV; only one scalar, rounded to hundredths, enters the recipe.
        var low = -5.0, high = 5.0, previousEV = 0.0, previousY = neutral
        for _ in 0..<7 {
            let residual = measured - target
            if abs(residual) < bestError { bestEV = ev; bestError = abs(residual) }
            if abs(residual) < 0.02 { break }
            if residual < 0 { low = ev } else { high = ev }
            let slope = ev == previousEV ? 1 : (measured - previousY) / (ev - previousEV)
            let next = ev - residual / max(0.1, slope)
            previousEV = ev; previousY = measured
            ev = min(high - 0.001, max(low + 0.001, next))
            measured = try await cameraDevelopmentBrightness(origin.url, options: options, exposure: Float(ev))
        }
        try origin.revision.validate(origin.url)
        if abs(measured - target) < bestError { bestEV = ev }
        return Float((bestEV * 100).rounded() / 100)
    }

    private func cameraDevelopmentBrightness(_ url: URL, options: SourceOptions, exposure: Float) async throws -> Double {
        try Task.checkCancellation()
        var options = options
        options.rawExposureBias = exposure
        let trial: RenderSource
        do {
            trial = try await load(url, options: options, allowsRAWCompatibilityFallback: false)
        } catch RenderError.cannotDecodeSource where options.draftRAWPreview {
            options.draftRAWPreview = false
            trial = try await load(url, options: options, allowsRAWCompatibilityFallback: false)
        }
        return try meterBrightness(smallMeterSource(trial), RenderAdjustments())
    }

    /// The centre-weighted log median of a RAW's embedded preview in linear
    /// Display P3, weighted as the `filmMeter` kernel weighs a render. Nil
    /// when the file is not a RAW or embeds no preview of a usable size; a
    /// preview is never manufactured by developing the RAW.
    static func cameraPreviewBrightness(_ url: URL) -> Double? {
        guard let file = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(file), let type = UTType(identifier as String),
              type.conforms(to: .rawImage),
              let image = CGImageSourceCreateThumbnailAtIndex(file, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256,
                  kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR
              ] as CFDictionary),
              min(image.width, image.height) >= 64 else { return nil }
        let scale = min(1, 192 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: Float.self, capacity: width * height * 4)
        let edge = Double(max(width, height))
        var samples: [(value: Double, weight: Double)] = []
        samples.reserveCapacity(width * height)
        for row in 0..<height {
            let y = (Double(row) / Double(height) - 0.5) * Double(height) / edge
            for column in 0..<width {
                let u = (Double(column) / Double(width) - 0.5) * Double(width) / edge
                let i = (row * width + column) * 4
                let luminance = max(1e-6, 0.2289746 * Double(pixels[i]) + 0.6917385 * Double(pixels[i + 1])
                    + 0.0792869 * Double(pixels[i + 2]))
                samples.append((log2(luminance), 0.5 + 0.5 * exp(-(u * u + y * y) / (2 * 0.04))))
            }
        }
        samples.sort { $0.value < $1.value }
        let halfway = samples.reduce(0) { $0 + $1.weight } / 2
        var weight = 0.0
        for sample in samples {
            weight += sample.weight
            if weight >= halfway { return sample.value }
        }
        return samples.last?.value
    }
}
