import Foundation
import CoreImage
import ImageIO
import Testing
import HyperDRRecipe
@testable import HyperDRRender

struct ToneToolsTests {
    @Test func strongerBlackPointAndClippingOverlay() async throws {
        let neutral = DoubleReference.RGB(repeating: 0.009)
        #expect(DoubleReference.point(neutral, operation: .blacks, value: 0) == neutral)
        #expect(DoubleReference.point(neutral, operation: .blacks, value: 1).x == 0)
        #expect(abs(DoubleReference.point(.zero, operation: .blacks, value: -1).x - 0.01341175) < 1e-7)
        let shadow = DoubleReference.RGB(0.001,0.002,0.006)
        let lifted = DoubleReference.point(shadow, operation: .blacks, value: -1)
        #expect(abs((lifted.z-lifted.x)-(shadow.z-shadow.x)) < 1e-12)
        let rgba: [Float] = [0,0,0,1, 0.009,0.009,0.009,1, 1,1,1,1]
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: 48,
                            size: CGSize(width: 3, height: 1), format: .RGBAf,
                            colorSpace: RenderEngine.workingColorSpace)
        let engine = try RenderEngine()
        let source = try await engine.source(image: image, domain: .sdr)
        var edit = RenderAdjustments(); edit.hdr.enabled = false; edit.tone.blacks = 1
        let planes = try await engine.render(source, adjustments: edit)
        let pair = try await engine.displayPair(planes, source: source)
        let mask = try await engine.clippingMask(pair, range: 3, hdrEnabled: false)
        let values = RenderEngine.readTexture(mask.texture)
        #expect(values == [1,0,1,0,0,1])
    }

    /// Opt-in review artifact generator; CI never opens a developer's photos.
    @Test func reviewWhiteAndBlackPoints() async throws {
        guard let samples = ProcessInfo.processInfo.environment["HYPERDR_TONE_REVIEW_SAMPLES"],
              let output = ProcessInfo.processInfo.environment["HYPERDR_TONE_REVIEW_OUTPUT"] else { return }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = try RenderEngine()
        for file in ["DSC01468.ARW", "IMG_3250.heic", "DSC01422.HIF"] {
            let source = try await engine.load(URL(fileURLWithPath: samples).appendingPathComponent(file),
                options: SourceOptions(resolution: .preview(maximumSize: .init(width: 1280, height: 1280))))
            for (label, whites, blacks): (String, Float, Float) in [
                ("before",0,0), ("whites-plus100",1,0), ("whites-minus100",-1,0),
                ("blacks-plus100",0,1), ("blacks-minus100",0,-1)] {
                var edit = RenderAdjustments(); edit.tone.whites = whites; edit.tone.blacks = blacks
                let planes = try await engine.render(source, adjustments: edit)
                let image = try await engine.sdrThumbnail(planes, maximumSize: .init(width: 1280, height: 1280))
                let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("\(file)-\(label).png") as CFURL,
                    "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            }
        }
    }
}
