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
        func gain(_ rgb: SIMD3<Double>, _ amount: Double = 1) -> Double {
            let lab = DoubleReference.oklab(rgb)
            let changed = DoubleReference.oklab(DoubleReference.vibrance(rgb, amount: amount))
            return hypot(changed.y,changed.z)/hypot(lab.y,lab.z)
        }
        #expect(gain(cool) > gain(skin))
        #expect(gain(cool,-1) < gain(skin,-1))
        for rgb in [skin, cool, skin*8] {
            #expect(DoubleReference.vibrance(rgb, amount: 0) == rgb)
            for amount in [-1.0, 1] {
                let result = DoubleReference.vibrance(rgb,amount:amount)
                #expect(abs(DoubleReference.luma(result)-DoubleReference.luma(rgb)) < 1e-8)
                #expect(hypot(DoubleReference.oklab(result).y,DoubleReference.oklab(result).z) > 0.001)
            }
        }
    }

    @Test func mixerUsesPreEditMembershipAndMatchesDouble() async throws {
        let engine = try RenderEngine(), rgb = SIMD3<Double>(0.08,0.35,0.12)
        let image = CIImage(color:CIColor(red:rgb.x,green:rgb.y,blue:rgb.z,
            colorSpace:RenderEngine.workingColorSpace)!).cropped(to:CGRect(x:0,y:0,width:8,height:8))
        let source = try await engine.source(image:image,domain:.rawEDR)
        let identity = RenderEngine.readPixels(try await engine.render(source,recipe:Recipe(inputDomain:.rawEDR)))
        #expect(abs(Double(identity.baseRGBA[0])-rgb.x)<1e-6)
        let recipe = Recipe(inputDomain:.rawEDR,values:["hsl.green.hue":.number(55),
            "hsl.green.saturation":.number(-70),"hsl.green.luminance":.number(20)])
        let settings = try RenderAdjustments(recipe:recipe)
        let expected = DoubleReference.prepare(rgb,settings:settings,sdr:false)
        let pixels = RenderEngine.readPixels(try await engine.render(source,recipe:recipe))
        for c in 0..<3 { #expect(abs(Double(pixels.baseRGBA[c])-expected.base[c])<2e-5) }
        #expect(abs(Double(pixels.baseRGBA[0])-rgb.x)>0.01)
        let sample = try await engine.pickHSL(source,recipe:recipe,at:CGPoint(x:0.5,y:0.5))
        let weights = DoubleReference.hslWeights(rgb)
        for i in 0..<8 { #expect(abs(sample.weights[i]-weights[i])<1e-5) }
        #expect(abs(weights.reduce(0,+)-1)<1e-6)
        #expect(DoubleReference.hslWeights(SIMD3(repeating:0.4)).reduce(0,+)==0)
    }

    @Test func gradingKeepsHDRLuminanceAndMatchesDouble() async throws {
        let engine = try RenderEngine()
        for level in [0.03,0.18,1.0,4.0] {
            let rgb = SIMD3<Double>(repeating:level)
            let image = CIImage(color:CIColor(red:level,green:level,blue:level,
                colorSpace:RenderEngine.workingColorSpace)!).cropped(to:CGRect(x:0,y:0,width:4,height:4))
            let source = try await engine.source(image:image,domain:.rawEDR)
            let recipe = Recipe(inputDomain:.rawEDR,values:["grade.shadows.hue":.number(220),
                "grade.shadows.saturation":.number(50),"grade.highlights.hue":.number(45),
                "grade.highlights.saturation":.number(50),"grade.global.hue":.number(30),
                "grade.global.saturation":.number(15),"hdr.range":.number(4)])
            let settings = try RenderAdjustments(recipe:recipe)
            let changed = DoubleReference.colorGrade(rgb,wheels:settings.color.grading)
            #expect(abs(DoubleReference.luma(changed)-level)<1e-8)
            let expected = DoubleReference.prepare(rgb,settings:settings,sdr:false)
            let pixels = RenderEngine.readPixels(try await engine.render(source,recipe:recipe))
            for c in 0..<3 {
                #expect(abs(Double(pixels.baseRGBA[c])-expected.base[c])<3e-5)
                #expect(abs(Double(pixels.gain[c])-expected.gains[c])<3e-5)
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_COLOR_REVIEW"] != nil))
    func localMixerComparison() async throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["HYPERDR_COLOR_REVIEW"]!)
        let output = root.appendingPathComponent("hsl")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for sample in ["DSC01468.ARW", "IMG_3891.HEIC", "DSC01422.HIF"] {
            let engine = try RenderEngine()
            let source = try await engine.load(URL(fileURLWithPath:"/Users/nxxxs/Desktop/HyperDR/测试照片/"+sample),options:SourceOptions(resolution:.preview(maximumSize:PixelSize(width:768,height:768))))
            let variants: [(String,[String:ParameterValue])] = [("before",[:]),
                ("blue-saturation",["hsl.blue.saturation":.number(80),"hsl.aqua.saturation":.number(40)]),
                ("green-hue",["hsl.green.hue":.number(65),"hsl.yellow.hue":.number(30)]),
                ("orange-luminance",["hsl.orange.luminance":.number(70),"hsl.red.luminance":.number(30)])]
            for (name,values) in variants {
                let recipe = Recipe(inputDomain:source.domain,values:values)
                try writeReview(RenderEngine.readPixels(try await engine.render(source,recipe:recipe)),to:output.appendingPathComponent(sample+"-"+name+".png"))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_COLOR_REVIEW"] != nil))
    func localGradingComparison() async throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["HYPERDR_COLOR_REVIEW"]!)
        let output = root.appendingPathComponent("grading")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for sample in ["DSC01468.ARW", "IMG_3891.HEIC", "DSC01422.HIF"] {
            let engine = try RenderEngine()
            let source = try await engine.load(URL(fileURLWithPath:"/Users/nxxxs/Desktop/HyperDR/测试照片/"+sample),options:SourceOptions(resolution:.preview(maximumSize:PixelSize(width:768,height:768))))
            let variants: [(String,[String:ParameterValue])] = [("before",[:]),
                ("teal-orange",["grade.shadows.hue":.number(220),"grade.shadows.saturation":.number(45),
                    "grade.highlights.hue":.number(50),"grade.highlights.saturation":.number(35),
                    "grade.midtones.hue":.number(30),"grade.midtones.saturation":.number(15)]),
                ("global-warm",["grade.global.hue":.number(55),"grade.global.saturation":.number(35)])]
            for (name,values) in variants {
                let recipe = Recipe(inputDomain:source.domain,values:values)
                try writeReview(RenderEngine.readPixels(try await engine.render(source,recipe:recipe)),to:output.appendingPathComponent(sample+"-"+name+".png"))
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
