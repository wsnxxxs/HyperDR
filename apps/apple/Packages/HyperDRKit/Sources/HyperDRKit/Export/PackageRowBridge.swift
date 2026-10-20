import Foundation
import HyperDREngine
import HyperDRRender

/// The native writer serializes callbacks. Only one stripe and a <=256px
/// thumbnail are retained; repeated reads never add a second thumbnail sample.
final class PackageRowBridge: @unchecked Sendable {
    let source: any ExportRowSource
    private let frame: FrameSnapshot?
    private let width, height, thumbnailWidth, thumbnailHeight: Int
    private let progress: @Sendable (RecipeExportProgress) -> Void
    /// Accessed on the writer's serial callback queue, then after it completes.
    private(set) var readSeconds: Double = 0
    private(set) var callbackSeconds: Double = 0
    private var progressEnd = 0
    private var progressPass = 1
    private var nextThumbnailRow = 0
    private var sums: [SIMD3<Double>]
    private var counts: [Int]

    init(source: any ExportRowSource, frame: FrameSnapshot?,
         progress: @escaping @Sendable (RecipeExportProgress) -> Void = { _ in }) {
        self.progress = progress
        self.source = source; self.frame = frame
        width = source.report.canvasSize.width; height = source.report.canvasSize.height
        let scale = min(1, 256 / Double(max(width, height)))
        thumbnailWidth = max(1, Int(Double(width) * scale)); thumbnailHeight = max(1, Int(Double(height) * scale))
        sums = .init(repeating: .zero, count: thumbnailWidth * thumbnailHeight)
        counts = .init(repeating: 0, count: sums.count)
    }

    func read(y: Int, count: Int, base: UnsafeMutableBufferPointer<Float>,
              gain: UnsafeMutableBufferPointer<Float>?) throws {
        let callbackStart = ContinuousClock.now
        defer {
            let elapsed = callbackStart.duration(to: .now).components
            callbackSeconds += Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        try Task.checkCancellation()
        guard y >= 0, count > 0, y <= height - count else { throw RecipeExportError.invalidStripes }
        let start = ContinuousClock.now
        let stripe: ExportStripe
        do {
            defer {
                let elapsed = start.duration(to: .now).components
                readSeconds += Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            }
            stripe = try source.read(y: y, count: count)
        }
        let channels = source.report.gain?.channelCount ?? 0
        guard stripe.rect == ExportRect(x: 0, y: y, width: width, height: count),
              stripe.baseRGB.count == width * count * 3, base.count == stripe.baseRGB.count,
              stripe.gain.count == width * count * channels,
              (gain?.count ?? 0) == stripe.gain.count,
              stripe.baseRGB.allSatisfy(\.isFinite), stripe.gain.allSatisfy(\.isFinite) else {
            throw RecipeExportError.invalidStripes
        }
        stripe.baseRGB.withUnsafeBufferPointer { base.baseAddress!.update(from: $0.baseAddress!, count: $0.count) }
        if let gain { stripe.gain.withUnsafeBufferPointer { gain.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
        if y <= nextThumbnailRow && nextThumbnailRow < y + count {
            for sy in nextThumbnailRow..<(y + count) {
                for x in 0..<width {
                    let i = ((sy-y)*width+x)*3
                    var value = SIMD3(Double(stripe.baseRGB[i]), Double(stripe.baseRGB[i+1]), Double(stripe.baseRGB[i+2]))
                    if let frame {
                        let inPhoto = x >= frame.photo.x && x < frame.photo.x + frame.photo.width
                            && sy >= frame.photo.y && sy < frame.photo.y + frame.photo.height
                        if !inPhoto { value = SIMD3(Double(frame.paper.x), Double(frame.paper.y), Double(frame.paper.z)) }
                    }
                    let destination = min(thumbnailHeight-1, sy*thumbnailHeight/height)*thumbnailWidth
                        + min(thumbnailWidth-1, x*thumbnailWidth/width)
                    sums[destination] += value; counts[destination] += 1
                }
            }
            nextThumbnailRow = y + count
        }
        try Task.checkCancellation()
        // Package may replay rows for extrema, base and auxiliary encoding.
        // Report each sequential pass, never count repeated callback samples twice.
        if y == 0 && progressEnd == height { progressPass += 1; progressEnd = 0 }
        if y <= progressEnd && y + count > progressEnd {
            progressEnd = y + count
            progress(.init(stage: .encoding, completedRows: progressEnd, totalRows: height,
                           includesRendering: true, rowPass: progressPass))
        }
    }

    func thumbnail() throws -> ExportThumbnail {
        guard nextThumbnailRow == height, counts.allSatisfy({ $0 > 0 }) else { throw RecipeExportError.invalidStripes }
        var pixels = [Float](); pixels.reserveCapacity(sums.count * 3)
        for i in sums.indices {
            let value = sums[i] / Double(counts[i])
            pixels.append(contentsOf: [Float(value.x), Float(value.y), Float(value.z)])
        }
        let original = source.report
        let collector = PackagePlaneCollector(width: thumbnailWidth, height: thumbnailHeight)
        try collector.prepare(.init(canvasSize: .init(width: thumbnailWidth, height: thumbnailHeight), gain: nil,
            sourceProvenance: original.sourceProvenance, provenance: original.provenance, resplitReasons: original.resplitReasons,
            rangeBeforeCeiling: original.rangeBeforeCeiling, rangeAfterCeiling: original.rangeAfterCeiling,
            resolvedAutomatic: original.resolvedAutomatic, presentationFrame: false, framePhoto: nil))
        try collector.consume(.init(rect: .init(x: 0, y: 0, width: thumbnailWidth, height: thumbnailHeight), baseRGB: pixels, gain: []))
        return try collector.thumbnail(captionFrame: frame)
    }
}
