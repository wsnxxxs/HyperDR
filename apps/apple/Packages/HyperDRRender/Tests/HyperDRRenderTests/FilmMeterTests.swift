import CoreGraphics
import CoreImage
import Foundation
import HyperDRRecipe
import ImageIO
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct FilmMeterTests {
    @Test(arguments: [0.025, 0.38], FilmStockID.allCases)
    func automaticPreservesDayAndNightBrightness(level: Double, stock: FilmStockID) async throws {
        let engine = try RenderEngine()
        let image = CIImage(color: CIColor(red: level, green: level, blue: level,
            colorSpace: RenderEngine.workingColorSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 24, height: 16))
        let source = try await engine.source(image: image, domain: .sdr)
        let ev = try await engine.filmMeter(source, stock: stock)
        let recipe = Recipe(inputDomain: .sdr, values: ["look.film": .string(stock.rawValue),
            "effect.grain": .number(0), "effect.halation": .number(0)])
        let pixels = RenderEngine.readPixels(try await engine.render(source, recipe: recipe))
        let y = Double(pixels.baseRGBA[0]) * 0.2289746 + Double(pixels.baseRGBA[1]) * 0.6917385 + Double(pixels.baseRGBA[2]) * 0.0792869
        #expect(abs(log2(y / level)) < 0.15, "\(stock) level \(level), auto \(ev): \(log2(y / level)) EV")
    }

    /// Opt-in visual evidence on local private samples. No sample paths enter logs
    /// during normal tests, and no large generated images enter the repository.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_FILM_REVIEW"] != nil))
    func localSampleComparison() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HYPERDR_FILM_REVIEW"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let samples = ["DSC01468.ARW", "DSC03078-A7M5.ARW", "1792403618000_R0000312.DNG"]
        var results = "sample,stock,oldExposure,newExposure,neutralMedian,oldMedian,newMedian,oldDeltaEV,newDeltaEV\n"
        func median(_ pixels: PlanePixels) -> Double {
            let w = pixels.size.width, h = pixels.size.height, edge = Double(max(w, h))
            let samples = (0..<h).flatMap { y in (0..<w).map { x -> (Double, Double) in
                let i = (y*w+x)*4
                let value = max(1e-6, Double(pixels.baseRGBA[i])*0.2289746 + Double(pixels.baseRGBA[i+1])*0.6917385 + Double(pixels.baseRGBA[i+2])*0.0792869)
                let dx = (Double(x)/Double(w)-0.5)*Double(w)/edge
                let dy = (Double(y)/Double(h)-0.5)*Double(h)/edge
                return (value, 0.5 + 0.5*exp(-(dx*dx+dy*dy)/0.08))
            }}.sorted { $0.0 < $1.0 }
            let half = samples.reduce(0) { $0 + $1.1 }/2
            var sum = 0.0
            for (value, weight) in samples { sum += weight; if sum >= half { return value } }
            return samples.last!.0
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
            let developed = median(neutralPixels)
            let preview = RenderEngine.cameraPreviewBrightness(file)
            let baseline = preview.flatMap { RenderEngine.acceptsCameraPreview($0, developed: log2(developed)) ? exp2($0) : nil } ?? developed
            try write(neutralPixels, sample+"-neutral")
            var options = SourceOptions(resolution: bound); options.sceneLinear = true
            let scene = try await engine.load(file, options: options)
            let raw = await engine.meterReviewInput(scene)
            var sum = 0.0, weights = 0.0
            let w = scene.size.width, h = scene.size.height, edge = Double(max(w,h))
            for y in 0..<h { for x in 0..<w {
                let dx = (Double(x)-Double(w)*0.5)/edge, dy = (Double(y)-Double(h)*0.5)/edge
                let weight = exp(-(dx*dx+dy*dy)/0.08), i = (y*w+x)*4
                sum += weight * max(0, Double(raw[i])*0.2289746+Double(raw[i+1])*0.6917385+Double(raw[i+2])*0.0792869)
                weights += weight
            } }
            let oldEV = min(3, max(-3, -log2(sum/weights/0.184)))
            for stock in FilmStockID.allCases {
                let newEV = try await engine.filmMeter(scene, stock: stock)
                var recipe = Recipe(inputDomain: .rawEDR, values: ["look.film": .string(stock.rawValue),
                    "effect.grain": .number(0), "effect.halation": .number(100)])
                let after = RenderEngine.readPixels(try await engine.render(scene, recipe: recipe))
                recipe.setValue(.number(oldEV), for: "look.filmExposure")
                let before = RenderEngine.readPixels(try await engine.render(scene, recipe: recipe))
                try write(before, sample+"-"+stock.rawValue+"-old")
                try write(after, sample+"-"+stock.rawValue+"-new")
                let old = median(before), new = median(after), delta = log2(new/baseline)
                let line = "\(sample),\(stock.rawValue),\(oldEV),\(newEV),\(baseline),\(old),\(new),\(log2(old/baseline)),\(delta)\n"
                results += line; print(line)
                try results.write(to: output.appendingPathComponent("brightness.csv"), atomically: true, encoding: .utf8)
                #expect(abs(delta) < (sample.hasSuffix("DNG") ? 0.2 : 0.15))
            }
        }
        try results.write(to: output.appendingPathComponent("brightness.csv"), atomically: true, encoding: .utf8)
    }
}

private extension RenderEngine {
    func meterReviewInput(_ source: RenderSource) -> [Float] { Self.readTexture(source.texture) }
}
