import CoreGraphics
import Foundation
import ImageIO
import HyperDREngine
import HyperDRRender

/// b-stage full-plane owner. The synchronous callback copies each stripe once;
/// pointers remain owned through the awaited C ABI call, never borrowed from Array.
final class PackagePlaneCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var base: UnsafeMutablePointer<Float>?
    private var gain: UnsafeMutablePointer<Float>?
    private(set) var report: ExportRenderReport?
    private var nextRow = 0
    private let width, height: Int
    init(width: Int, height: Int) { self.width = width; self.height = height }
    deinit { base?.deallocate(); gain?.deallocate() }

    func prepare(_ report: ExportRenderReport) throws {
        try lock.withLock {
            guard self.report == nil, report.canvasSize.width == width, report.canvasSize.height == height,
                  width > 0, height > 0, width <= Int.max / height / 16,
                  report.gain == nil || [1, 3].contains(report.gain!.channelCount) else {
                throw RecipeExportError.invalidStripes
            }
            self.report = report
            base = .allocate(capacity: width * height * 3)
            if let channels = report.gain?.channelCount { gain = .allocate(capacity: width * height * channels) }
        }
    }
    func consume(_ stripe: ExportStripe) throws {
        try Task.checkCancellation()
        try lock.withLock {
            let r = stripe.rect
            guard let report, let base, r.x == 0, r.y == nextRow, r.width == width,
                  r.height > 0, r.height <= height - nextRow,
                  stripe.baseRGB.count == width * r.height * 3,
                  stripe.gain.count == width * r.height * (report.gain?.channelCount ?? 0),
                  stripe.baseRGB.allSatisfy(\.isFinite), stripe.gain.allSatisfy(\.isFinite) else {
                throw RecipeExportError.invalidStripes
            }
            stripe.baseRGB.withUnsafeBufferPointer { values in
                base.advanced(by: nextRow * width * 3).initialize(from: values.baseAddress!, count: values.count)
            }
            if let gain, let channels = report.gain?.channelCount {
                stripe.gain.withUnsafeBufferPointer { values in
                    gain.advanced(by: nextRow * width * channels).initialize(from: values.baseAddress!, count: values.count)
                }
            }
            nextRow += r.height
        }
        try Task.checkCancellation()
    }
    func completed() throws -> ExportRenderReport {
        try lock.withLock {
            guard let report, nextRow == height else { throw RecipeExportError.invalidStripes }
            return report
        }
    }
    var basePlane: PackagePlane {
        .init(samples: .init(start: base!, count: width * height * 3), width: width, height: height, channels: 3)
    }
    var gainPlane: PackagePlane? {
        guard let gain, let channels = report?.gain?.channelCount else { return nil }
        return .init(samples: .init(start: gain, count: width * height * channels), width: width, height: height, channels: channels)
    }
    func thumbnail(frame: FrameSnapshot? = nil, captionFrame: FrameSnapshot? = nil) throws -> ExportThumbnail {
        _ = try completed()
        let scale = min(1, 256.0 / Double(max(width, height)))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let x0 = x * width / w, x1 = max(x0 + 1, (x + 1) * width / w)
                let y0 = y * height / h, y1 = max(y0 + 1, (y + 1) * height / h)
                var sum = SIMD3<Double>.zero
                for sy in y0..<y1 { for sx in x0..<x1 {
                    if let frame, (sx < frame.photo.x || sx >= frame.photo.x + frame.photo.width
                        || sy < frame.photo.y || sy >= frame.photo.y + frame.photo.height) {
                        sum += SIMD3(Double(frame.paper.x), Double(frame.paper.y), Double(frame.paper.z))
                    } else {
                        let i = (sy * width + sx) * 3
                        sum += SIMD3(Double(base![i]), Double(base![i+1]), Double(base![i+2]))
                    }
                } }
                sum /= Double((x1-x0)*(y1-y0))
                for c in 0..<3 {
                    let v = max(0, min(1, sum[c]))
                    let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1/2.4) - 0.055
                    bytes[(y*w+x)*4+c] = UInt8((encoded*255).rounded())
                }
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data), let space = CGColorSpace(name: CGColorSpace.displayP3),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w*4, space: space, bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw RecipeExportError.invalidStripes
        }
        let overlayFrame = captionFrame ?? frame
        if let caption = overlayFrame?.caption,
           let source = CGImageSourceCreateWithData(caption.png as CFData, nil),
           let overlay = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary),
           let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let sx = Double(w)/Double(overlayFrame?.canvasSize.width ?? width)
            let sy = Double(h)/Double(overlayFrame?.canvasSize.height ?? height)
            context.draw(overlay, in: CGRect(x: Double(caption.rect.x)*sx,
                y: Double(h)-Double(caption.rect.y+caption.rect.height)*sy,
                width: Double(caption.rect.width)*sx, height: Double(caption.rect.height)*sy))
            guard let card = context.makeImage() else { throw RecipeExportError.invalidStripes }
            return try ExportThumbnail(image: card)
        }
        return try ExportThumbnail(image: image)
    }
}
