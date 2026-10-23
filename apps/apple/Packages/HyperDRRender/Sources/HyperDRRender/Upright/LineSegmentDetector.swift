import Accelerate
import CoreGraphics
import Foundation
import HyperDRRecipe

/// A small, independent LSD-style detector (Grompone von Gioi et al., IPOL
/// 2012): 2×2 gradients, strongest-first level-line region growing and a
/// gradient-weighted rectangle fit. Length, alignment and occupied-rectangle
/// density replace LSD's statistical NFA test. No Vision or auto adjustment.
/// Call off the main actor; cancellation is checked during both pixel passes.
public enum LineSegmentDetector {
    public enum DetectionError: Error { case invalidImage, bitmapContext }

    /// Returns centred, y-down segments in the caller's untransformed photo
    /// pixels (the image must have the same orientation and aspect as it).
    public static func detect(_ image: CGImage, photoSize: GeometrySize? = nil,
                              maximumSide: Int = 1536) throws -> [UprightLine] {
        let side = max(32, min(maximumSide, 1600))
        let scale = min(1, Double(side) / Double(max(image.width, image.height)))
        let width = max(2, Int((Double(image.width) * scale).rounded()))
        let height = max(2, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw DetectionError.bitmapContext }
        var gray = [Float](repeating: 0, count: bytes.count)
        vDSP_vfltu8(bytes, 1, &gray, 1, vDSP_Length(bytes.count))
        return try detect(gray: gray, width: width, height: height,
                          photoSize: photoSize ?? GeometrySize(width: Double(image.width), height: Double(image.height)))
    }

    /// Gray samples in 0...255, row-major from the top left. This low-level
    /// entry point does not resize; callers should bound the long edge to 1600.
    public static func detect(gray: [Float], width: Int, height: Int,
                              photoSize: GeometrySize) throws -> [UprightLine] {
        guard width >= 3, height >= 3, width <= 1600, height <= 1600,
              gray.count == width * height, photoSize.width.isFinite, photoSize.height.isFinite,
              min(photoSize.width, photoSize.height) > 0 else { throw DetectionError.invalidImage }
        let count = gray.count
        var nx = [Float](repeating: 0, count: count), ny = nx, magnitude = nx
        var magnitudeSum: Float = 0
        for y in 0..<(height - 1) {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<(width - 1) {
                let i = y * width + x
                let dx = (gray[i + 1] + gray[i + width + 1] - gray[i] - gray[i + width]) * 0.5
                let dy = (gray[i + width] + gray[i + width + 1] - gray[i] - gray[i + 1]) * 0.5
                let m = sqrt(dx * dx + dy * dy)
                if m.isFinite, m > 0 {
                    nx[i] = dx / m; ny[i] = dy / m; magnitude[i] = m; magnitudeSum += m
                }
            }
        }
        let threshold = max(5, magnitudeSum / Float(count) * 1.4)
        var buckets = [[Int]](repeating: [], count: 64)
        for i in 0..<count where magnitude[i] >= threshold {
            buckets[min(63, Int(magnitude[i] / 4))].append(i)
        }
        var visited = [Bool](repeating: false, count: count)
        var region = [Int]()
        region.reserveCapacity(4096)
        let cosine: Float = 0.9659258 // 15 degrees, signed gradient polarity.
        let minimumLength = max(18, Double(max(width, height)) * 0.025)
        let sx = photoSize.width / Double(width), sy = photoSize.height / Double(height)
        var result = [UprightLine]()
        for bucket in buckets.reversed() {
            for seed in bucket where !visited[seed] {
                if seed % 257 == 0 { try Task.checkCancellation() }
                region.removeAll(keepingCapacity: true)
                region.append(seed); visited[seed] = true
                var cursor = 0
                var meanX = nx[seed], meanY = ny[seed]
                var sumX = meanX * magnitude[seed], sumY = meanY * magnitude[seed]
                while cursor < region.count {
                    let i = region[cursor], x = i % width, y = i / width
                    cursor += 1
                    if cursor % 4096 == 0 { try Task.checkCancellation() }
                    for yy in max(0, y - 1)...min(height - 2, y + 1) {
                        for xx in max(0, x - 1)...min(width - 2, x + 1) {
                            let j = yy * width + xx
                            if !visited[j], magnitude[j] >= threshold, nx[j] * meanX + ny[j] * meanY >= cosine {
                                visited[j] = true; region.append(j)
                                sumX += nx[j] * magnitude[j]; sumY += ny[j] * magnitude[j]
                                let norm = max(sqrt(sumX * sumX + sumY * sumY), 1e-10)
                                meanX = sumX / norm; meanY = sumY / norm
                            }
                        }
                    }
                }
                guard region.count >= Int(minimumLength * 0.7) else { continue }
                var mass = 0.0, cx = 0.0, cy = 0.0
                for i in region {
                    let w = Double(magnitude[i])
                    mass += w; cx += (Double(i % width) + 0.5) * w; cy += (Double(i / width) + 0.5) * w
                }
                cx /= mass; cy /= mass
                var xx = 0.0, xy = 0.0, yy = 0.0
                for i in region {
                    let x = Double(i % width) + 0.5 - cx, y = Double(i / width) + 0.5 - cy
                    let w = Double(magnitude[i])
                    xx += w * x * x; xy += w * x * y; yy += w * y * y
                }
                let direction = 0.5 * atan2(2 * xy, xx - yy)
                let dx = cos(direction), dy = sin(direction)
                var low = Double.infinity, high = -Double.infinity
                var lowN = Double.infinity, highN = -Double.infinity
                var aligned = 0
                for i in region {
                    let x = Double(i % width) + 0.5 - cx, y = Double(i / width) + 0.5 - cy
                    let along = x * dx + y * dy, normal = -x * dy + y * dx
                    low = min(low, along); high = max(high, along)
                    lowN = min(lowN, normal); highN = max(highN, normal)
                    if abs(Double(nx[i]) * dy - Double(ny[i]) * dx) >= Double(cosine) { aligned += 1 }
                }
                let length = high - low, thickness = max(1, highN - lowN + 1)
                let alignment = Double(aligned) / Double(region.count)
                let density = Double(region.count) / max(length * thickness, 1)
                guard length >= minimumLength, length >= thickness * 5, alignment >= 0.8, density >= 0.45 else { continue }
                let normalCentre = (lowN + highN) / 2
                func point(_ t: Double) -> GeometryPoint {
                    GeometryPoint(x: (cx + t * dx - normalCentre * dy) * sx - photoSize.width / 2,
                                  y: (cy + t * dy + normalCentre * dx) * sy - photoSize.height / 2)
                }
                result.append(UprightLine(start: point(low), end: point(high), width: thickness * (sx + sy) / 2,
                                          confidence: min(1, density) * alignment))
            }
            try Task.checkCancellation()
        }
        return Array(result.sorted { $0.length * $0.confidence > $1.length * $1.confidence }.prefix(1200))
    }
}
