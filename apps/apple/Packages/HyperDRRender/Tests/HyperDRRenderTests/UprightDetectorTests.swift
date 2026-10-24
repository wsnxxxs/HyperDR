import CoreGraphics
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRRender

@Suite struct UprightDetectorTests {
    func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 800, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        context.translateBy(x: 0, y: 600)
        context.scaleBy(x: 1, y: -1) // Draw in the solver's top-left, y-down coordinates.
        context.setStrokeColor(gray: 0.9, alpha: 1)
        context.setLineWidth(3)
        let inverse = Geometry(angle: 9, vertical: 24, horizontal: -18)
            .transform(for: GeometrySize(width: 800, height: 600)).inverse
        func draw(_ a: GeometryPoint, _ b: GeometryPoint) {
            let a = inverse.apply(a), b = inverse.apply(b)
            context.move(to: CGPoint(x: a.x + 400, y: a.y + 300))
            context.addLine(to: CGPoint(x: b.x + 400, y: b.y + 300))
            context.strokePath()
        }
        for k in -3...3 {
            draw(GeometryPoint(x: Double(k) * 75, y: -190), GeometryPoint(x: Double(k) * 75, y: 190))
            draw(GeometryPoint(x: -290, y: Double(k) * 55), GeometryPoint(x: 290, y: Double(k) * 55))
        }
        return try #require(context.makeImage())
    }

    @Test func detectsTiltedBuildingGridAndFitsTheActualHomography() throws {
        let image = try image()
        let size = GeometrySize(width: 800, height: 600)
        let lines = try LineSegmentDetector.detect(image, photoSize: size)
        #expect(lines.count >= 14)
        let target = Geometry(angle: 9, vertical: 24, horizontal: -18).transform(for: size)
        let aligned = lines.filter { line in
            let a = target.apply(line.start), b = target.apply(line.end)
            let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
            return min(dx, dy) / hypot(dx, dy) < 0.025
        }
        #expect(Double(aligned.count) / Double(max(lines.count, 1)) > 0.9)
        let result = try #require(UprightSolver.solve(lines: lines, photo: size, geometry: .identity, mode: .full))
        #expect(abs(result.angle - 9) < 0.25)
        #expect(abs(result.vertical - 24) < 3)
        #expect(abs(result.horizontal + 18) < 3)
    }

    @Test func detectorCoordinatesScaleBackToPhotoPixelsAndFlatImagesHaveNoLines() throws {
        let image = try image()
        let base = try LineSegmentDetector.detect(image)
        let scaled = try LineSegmentDetector.detect(image, photoSize: GeometrySize(width: 4000, height: 3000))
        #expect(base.count == scaled.count)
        for (a, b) in zip(base, scaled) {
            #expect(abs(a.start.x * 5 - b.start.x) < 1e-8)
            #expect(abs(a.start.y * 5 - b.start.y) < 1e-8)
            #expect(abs(a.width * 5 - b.width) < 1e-8)
        }
        #expect(try LineSegmentDetector.detect(gray: [Float](repeating: 128, count: 10000), width: 100, height: 100,
                                               photoSize: GeometrySize(width: 100, height: 100)).isEmpty)
    }
}
