import CoreGraphics
import Foundation

/// The numbers behind the scope drawings, apart from the drawing, so they
/// can be tested without a view.
enum ScopeMath {
    /// Space kept above the highest curve point, in points.
    static let curveHeadroom: CGFloat = 6
    /// A waveform cell fainter than this is not drawn.
    static let waveformFloor = 0.12

    /// The largest count among `arrays`; the common scale of every curve in
    /// one histogram, so the original and the edited frame stay comparable.
    static func peak(_ arrays: [[UInt32]]) -> Double {
        Double(arrays.lazy.compactMap { $0.max() }.max() ?? 0)
    }

    /// `sqrt(count / peak)` for each bin: counts compressed so that a small
    /// tail still shows beside a large peak.
    static func curve(_ counts: [UInt32], peak: Double) -> [Double] {
        guard peak > 0 else { return counts.map { _ in 0 } }
        return counts.map { min(1, (Double($0) / peak).squareRoot()) }
    }

    /// The height of a curve value in a plot `height` points tall, measured
    /// from the top (0 is the top edge).
    static func y(for value: Double, height: CGFloat) -> CGFloat {
        height - CGFloat(value) * (height - curveHeadroom)
    }

    /// A waveform cell's opacity: its count as a share of the busiest cell
    /// of its column, so a column's trace fades away from its core (the
    /// design note's "square of the square root"), or nil when too faint to
    /// draw.
    static func waveformOpacity(count: UInt32, columnMax: UInt32) -> Double? {
        guard columnMax > 0, count > 0 else { return nil }
        let opacity = Double(count) / Double(columnMax)
        return opacity < waveformFloor ? nil : min(opacity, 1)
    }

    /// An alpha mask of the waveform, white with the cell's opacity as alpha,
    /// as tall as it has rows (row 0, black, at the bottom). The plot tints
    /// it. Nil for an empty or inconsistent grid.
    static func waveformMask(_ waveform: WaveformCounts) -> CGImage? {
        let columns = waveform.columns, rows = waveform.rows
        guard columns > 0, rows > 0, waveform.counts.count == columns * rows else { return nil }
        var columnMax = [UInt32](repeating: 0, count: columns)
        for row in 0..<rows {
            for column in 0..<columns {
                columnMax[column] = max(columnMax[column], waveform.counts[row * columns + column])
            }
        }
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for row in 0..<rows {
            let y = rows - 1 - row
            for column in 0..<columns {
                guard let opacity = waveformOpacity(count: waveform.counts[row * columns + column],
                                                    columnMax: columnMax[column]) else { continue }
                let alpha = UInt8((opacity * 255).rounded())
                let offset = (y * columns + column) * 4
                // Premultiplied white.
                pixels[offset] = alpha
                pixels[offset + 1] = alpha
                pixels[offset + 2] = alpha
                pixels[offset + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The ceiling label's text, apart from the unit: nil for a ceiling at
    /// SDR white (colour-only processing), where only "Limit" is written.
    static func ceilingValue(stops: Double) -> String? {
        stops > 0.05 ? stops.formatted(.number.precision(.fractionLength(1))) : nil
    }
}
