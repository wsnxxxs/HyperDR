import CoreImage
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRRender

@Suite struct WhiteBalancePickTests {
    @Test func pickingTintedSourceProducesNeutralPixel() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CIContext()
        let space = RenderEngine.workingColorSpace
        let image = CIImage(color: CIColor(red: 0.25, green: 0.29, blue: 0.32, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        try context.writePNGRepresentation(of: image, to: url, format: .RGBA16, colorSpace: space)
        let engine = try RenderEngine()
        let sample = try await engine.pickWhiteBalance(url, options: SourceOptions(), point: CGPoint(x: 0.5, y: 0.5),
                                                       photoSize: PixelSize(width: 32, height: 24), raw: false)
        let warm = DoubleReference.point(SIMD3(0.25, 0.29, 0.32), operation: .warmth, value: sample.temperature / 100)
        let neutral = DoubleReference.point(warm, operation: .tint, value: sample.tint / 100)
        #expect(abs(neutral.x - neutral.y) < 0.001)
        #expect(abs(neutral.z - neutral.y) < 0.001)
    }
}
