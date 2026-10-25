import CoreGraphics
import CoreImage
import Foundation
import HyperDRRecipe
import ImageIO
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct LUTMeterTests {
    @Test func automaticMatchesDisplayAndStrengthReusesTheMeter() async throws {
        let engine = try RenderEngine()
        let image = CIImage(color:CIColor(red:0.18,green:0.18,blue:0.18,
            colorSpace:RenderEngine.workingColorSpace)!).cropped(to:CGRect(x:0,y:0,width:16,height:16))
        let source = try await engine.source(image:image,domain:.rawEDR)
        let lut = try ColorLUT(cube:"LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        var recipe = Recipe(inputDomain:.rawEDR,look:LUTReference(contentHash:lut.contentHash,name:"Log"),
            values:["look.input":.string("flog2-fgamut"),"look.output":.string("rec709")])
        let pixels = RenderEngine.readPixels(try await engine.render(source,recipe:recipe,lut:lut))
        #expect(abs(log2(Double(pixels.baseRGBA[0])/0.18))<0.02)
        let first = try await engine.resolvedAutomatic(source,recipe:recipe,lut:lut)["look.exposure"]
        #expect(first != nil && first! > 0)
        recipe.setValue(.number(40),for:"look.strength")
        let second = try await engine.resolvedAutomatic(source,recipe:recipe,lut:lut)["look.exposure"]
        #expect(first == second)
        #expect(await engine.lutMeterEntryCount() == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_LUT_REVIEW"] != nil))
    func localSpaceComparison() async throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["HYPERDR_LUT_REVIEW"]!).deletingLastPathComponent()
        let output = root.appendingPathComponent("spaces")
        let engine = try RenderEngine()
        var options = SourceOptions(resolution:.preview(maximumSize:PixelSize(width:768,height:768)))
        options.sceneLinear = true
        let source = try await engine.load(URL(fileURLWithPath:"/Users/nxxxs/Desktop/HyperDR/测试照片/DSC01468.ARW"),options:options)
        let groups: [(String,String,LUTSpace)] = [("F-Log","FLog",.flogFGamut),
            ("F-Log2","FLog2",.flog2FGamut),("F-Log2C","FLog2C",.flog2cFGamutC)]
        for (folder,prefix,space) in groups {
            let path = "vendor/gfx-eterna-55-3d-lut-v110/33Grid/"+folder+"/"+prefix+"_to_ETERNA_33grid_V.1.00.cube"
            let lut = try ColorLUT(data:Data(contentsOf:output.appendingPathComponent(path)))
            for (name,input) in [("old",LUTSpace.flog2FGamut),("new",space)] {
                var edit = RenderAdjustments()
                edit.look.lut = lut; edit.look.input = input; edit.look.output = .rec709
                edit.look.exposure = try await engine.lutMeter(source,lut:lut,input:input,output:.rec709)
                try writeReview(RenderEngine.readPixels(try await engine.render(source,adjustments:edit)),
                    to:output.appendingPathComponent("DSC01468.ARW-"+prefix+"-"+name+".png"))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_LUT_REVIEW"] != nil))
    func localSampleComparison() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HYPERDR_LUT_REVIEW"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let samples = ["DSC01468.ARW", "DSC03078-A7M5.ARW"]
        var results = "sample,stock,oldExposure,newExposure,neutralMedian,oldMedian,newMedian,oldDeltaEV,newDeltaEV\n"
        func median(_ pixels: PlanePixels) -> Double {
            let values = stride(from: 0, to: pixels.baseRGBA.count, by: 4).map { i in
                Double(pixels.baseRGBA[i])*0.2289746 + Double(pixels.baseRGBA[i+1])*0.6917385 + Double(pixels.baseRGBA[i+2])*0.0792869
            }.sorted()
            return values[values.count/2]
        }
        func write(_ pixels: PlanePixels, _ name: String) throws {
            let image = CIImage(bitmapData: pixels.baseRGBA.withUnsafeBytes { Data($0) }, bytesPerRow: pixels.size.width*16,
                size: CGSize(width: pixels.size.width, height: pixels.size.height), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
            let cg = try #require(CIContext().createCGImage(image, from: image.extent, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            let destination = try #require(CGImageDestinationCreateWithURL(output.appendingPathComponent(name+".png") as CFURL,
                "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, cg, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        for sample in samples {
            let engine = try RenderEngine()
            let file = URL(fileURLWithPath: "/Users/nxxxs/Desktop/HyperDR/测试照片/"+sample)
            let bound = SourceResolution.preview(maximumSize: PixelSize(width: 1024, height: 1024))
            let neutral = try await engine.load(file, options: SourceOptions(resolution: bound))
            let neutralPixels = RenderEngine.readPixels(try await engine.render(neutral, recipe: Recipe(inputDomain: .rawEDR)))
            let baseline = median(neutralPixels)
            try write(neutralPixels, sample+"-neutral")
            var options = SourceOptions(resolution: bound); options.sceneLinear = true
            let scene = try await engine.load(file, options: options)
            for stock in ["PROVIA", "ETERNA", "CLASSIC-CHROME"] {
                let lutFile = output.deletingLastPathComponent().appendingPathComponent("spaces/vendor/gfx-eterna-55-3d-lut-v110/33Grid/F-Log2/FLog2_to_"+stock+"_33grid_V.1.00.cube")
                let lut = try ColorLUT(data: Data(contentsOf: lutFile))
                let newEV = try await engine.lutMeter(scene, lut: lut, input: .flog2FGamut, output: .rec709)
                let oldEV = 0.0
                var recipe = Recipe(inputDomain: .rawEDR, look: LUTReference(contentHash: lut.contentHash, name: stock), values: ["look.input": .string("flog2-fgamut"), "look.output": .string("rec709")])
                let after = RenderEngine.readPixels(try await engine.render(scene, recipe: recipe, lut: lut))
                recipe.setValue(.number(oldEV), for: "look.exposure")
                let before = RenderEngine.readPixels(try await engine.render(scene, recipe: recipe, lut: lut))
                try write(before, sample+"-"+stock+"-old")
                try write(after, sample+"-"+stock+"-new")
                let old = median(before), new = median(after), delta = log2(new/baseline)
                let line = "\(sample),\(stock),\(oldEV),\(newEV),\(baseline),\(old),\(new),\(log2(old/baseline)),\(delta)\n"
                results += line; print(line)
                try results.write(to: output.appendingPathComponent("brightness.csv"), atomically: true, encoding: .utf8)
                #expect(abs(delta) < (sample.hasSuffix("DNG") ? 0.2 : 0.15))
            }
        }
        try results.write(to: output.appendingPathComponent("brightness.csv"), atomically: true, encoding: .utf8)
    }
}

private extension RenderEngine {
    func lutMeterEntryCount() -> Int { lutMeterCache.count }
}
