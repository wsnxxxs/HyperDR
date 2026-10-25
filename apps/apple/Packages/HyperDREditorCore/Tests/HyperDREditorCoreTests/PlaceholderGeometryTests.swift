import CoreGraphics
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDREditorCore

@Suite struct PlaceholderGeometryTests {
    /// 200×100: red on the left half, blue on the right half.
    private func photo() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        return try #require(context.makeImage())
    }

    private func centre(_ image: CGImage) throws -> (r: UInt8, b: UInt8) {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (bytes[0], bytes[2])
    }

    @Test func cropKeepsOnlyItsPartAtThePhotosProportions() throws {
        var geometry = Geometry()
        geometry.aspect = .free
        geometry.crop = CropRect(centreX: 0.25, centreY: 0, width: 0.5, height: 1)
        let laid = try #require(PlaceholderGeometry.apply(geometry, to: try photo(), photo: CGSize(width: 200, height: 100)))
        #expect(laid.size == CGSize(width: 100, height: 100))
        #expect(laid.image.width == 100 && laid.image.height == 100)
        let colour = try centre(laid.image)
        #expect(colour.b > 200 && colour.r < 50)
    }

    @Test func aQuarterTurnSwapsTheProportions() throws {
        var geometry = Geometry()
        geometry.quarterTurns = 1
        let laid = try #require(PlaceholderGeometry.apply(geometry, to: try photo(), photo: CGSize(width: 200, height: 100)))
        #expect(laid.size == CGSize(width: 100, height: 200))
        #expect(laid.image.width == 100 && laid.image.height == 200)
    }

    @Test func noGeometryLeavesTheThumbnailAlone() throws {
        #expect(PlaceholderGeometry.apply(Geometry(), to: try photo(), photo: CGSize(width: 200, height: 100)) == nil)
    }
}
