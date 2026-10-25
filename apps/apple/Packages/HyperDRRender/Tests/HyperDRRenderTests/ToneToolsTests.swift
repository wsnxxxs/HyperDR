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
            let curves = ProcessInfo.processInfo.environment["HYPERDR_TONE_REVIEW_CURVES"] != nil
            let spatial = ProcessInfo.processInfo.environment["HYPERDR_TONE_REVIEW_SPATIAL"] != nil
            let modes: [(String,Float,Float)] = spatial
                ? [("before",0,0),("dehaze-plus100",0,0),("dehaze-minus100",0,0),("clarity-plus100",0,0),("clarity-minus100",0,0)]
                : curves
                ? [("before",0,0),("curve-both",0,0),("curve-sdr",0,0),("curve-hdr",0,0),("curve-rgb",0,0),("curve-parametric",0,0)]
                : [("before",0,0),("whites-plus100",1,0),("whites-minus100",-1,0),("blacks-plus100",0,1),("blacks-minus100",0,-1)]
            for (label, whites, blacks) in modes {
                var edit = RenderAdjustments(); edit.tone.whites = whites; edit.tone.blacks = blacks
                if label == "dehaze-plus100" { edit.tone.dehaze = 1 }
                if label == "dehaze-minus100" { edit.tone.dehaze = -1 }
                if label == "clarity-plus100" { edit.tone.clarity = 1 }
                if label == "clarity-minus100" { edit.tone.clarity = -1 }
                if label == "curve-both" { edit.tone.curve = try ToneCurve([0,0,0.3,0.22,0.7,0.8,1,1,3,2.4]) }
                if label == "curve-sdr" { edit.tone.curveSDR = try ToneCurve([0,0,0.5,0.4,1,1]) }
                if label == "curve-hdr" { edit.tone.curveHDR = try ToneCurve([0,0,0.5,0.65,1,1,3,2.4]) }
                if label == "curve-rgb" { edit.tone.curveRed = try ToneCurve([0,0,0.5,0.6,1,1]) }
                if label == "curve-parametric" { edit.tone.parametricLights = 0.75; edit.tone.parametricShadows = -0.5 }
                let planes = try await engine.render(source, adjustments: edit)
                let image = try await engine.sdrThumbnail(planes, maximumSize: .init(width: 1280, height: 1280))
                let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("\(file)-\(label).png") as CFURL,
                    "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
                if curves || spatial {
                    let pair = try await engine.displayPair(planes,source: source)
                    let hdr = try await engine.reviewHDRThumbnail(pair)
                    let file = root.appendingPathComponent("\(file)-\(label)-HDR-minus2EV.png")
                    let target = CGImageDestinationCreateWithURL(file as CFURL,"public.png" as CFString,1,nil)!
                    CGImageDestinationAddImage(target,hdr,nil)
                    #expect(CGImageDestinationFinalize(target))
                }
            }
        }
    }
}

extension RenderEngine {
    func reviewHDRThumbnail(_ pair: DisplayGainPair) throws -> CGImage {
        let command = queue.makeCommandBuffer()!
        let texture = try encodeDisplayHDR(pair,into: command)
        try finish(command)
        let image = CIImage(mtlTexture: texture,options: [.colorSpace: Self.workingColorSpace])!
            .transformed(by: CGAffineTransform(a: 1,b: 0,c: 0,d: -1,tx: 0,ty: CGFloat(texture.height)))
            .applyingFilter("CIExposureAdjust",parameters: [kCIInputEVKey: -2])
        return context.createCGImage(image,from: image.extent,format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)!
    }
}
