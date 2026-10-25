import CoreGraphics
import CoreImage
import Foundation
import HyperDRRecipe
import ImageIO
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct ColorToolsTests {
    @Test func vibranceKeepsLuminanceAndProtectsSkin() {
        let skin = DoubleReference.oklabRGB(SIMD3(0.65, 0.06, 0.07))
        let cool = DoubleReference.oklabRGB(SIMD3(0.65, -0.06, -0.07))
        func gain(_ rgb: SIMD3<Double>) -> Double {
            let lab = DoubleReference.oklab(rgb)
            let changed = DoubleReference.oklab(DoubleReference.vibrance(rgb, amount: 1))
            return hypot(changed.y,changed.z)/hypot(lab.y,lab.z)
        }
        #expect(gain(cool) > gain(skin))
        for rgb in [skin, cool, skin*8] {
            #expect(DoubleReference.vibrance(rgb, amount: 0) == rgb)
            for amount in [-1.0, 1] {
                let result = DoubleReference.vibrance(rgb,amount:amount)
                #expect(abs(DoubleReference.luma(result)-DoubleReference.luma(rgb)) < 1e-8)
                #expect(hypot(DoubleReference.oklab(result).y,DoubleReference.oklab(result).z) > 0.001)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_COLOR_REVIEW"] != nil))
    func localVibranceComparison() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HYPERDR_COLOR_REVIEW"]!)
        let output = root.appendingPathComponent("vibrance")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for sample in ["DSC01468.ARW", "IMG_3891.HEIC", "DSC01422.HIF"] {
            let engine = try RenderEngine()
            let source = try await engine.load(URL(fileURLWithPath:"/Users/nxxxs/Desktop/HyperDR/测试照片/"+sample), options: SourceOptions(resolution:.preview(maximumSize:PixelSize(width:768,height:768))))
            for amount in [-100.0, 0, 100] {
                let recipe = Recipe(inputDomain:source.domain,values:["color.vibrance":.number(amount)])
                let pixels = RenderEngine.readPixels(try await engine.render(source,recipe:recipe))
                try writeReview(pixels,to:output.appendingPathComponent(sample+"-\(Int(amount)).png"))
            }
        }
    }
}

func writeReview(_ pixels: PlanePixels, to url: URL) throws {
    let image = CIImage(bitmapData: pixels.baseRGBA.withUnsafeBytes { Data($0) }, bytesPerRow:pixels.size.width*16,
        size:CGSize(width:pixels.size.width,height:pixels.size.height),format:.RGBAf,colorSpace:RenderEngine.workingColorSpace)
    let cg = try #require(CIContext().createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,cg,nil)
    #expect(CGImageDestinationFinalize(destination))
}
