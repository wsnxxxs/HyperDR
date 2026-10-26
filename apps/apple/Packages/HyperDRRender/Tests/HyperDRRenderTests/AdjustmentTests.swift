import Foundation
import CoreImage
import CryptoKit
import ImageIO
import Metal
import Testing
import HyperDRRecipe
@testable import HyperDRRender

private func bitmap(_ values: [SIMD3<Double>], width: Int, height: Int) -> CIImage {
    let rgba = values.map { SIMD4(Float($0.x),Float($0.y),Float($0.z),1) }
    return CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow:width*16,
        size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:RenderEngine.workingColorSpace)
}
private func code(_ value: Double, hdr: Bool = false) -> Int {
    if hdr {
        let p = pow(max(0,value)*0.0203,2610/16384)
        return Int((pow((3424/4096+(2413/128)*p)/(1+(2392/128)*p),2523/32)*1023).rounded())
    }
    let x = min(1,max(0,value)), encoded = x <= 0.0031308 ? x*12.92 : 1.055*pow(x,1/2.4)-0.055
    return Int((encoded*1023).rounded())
}
private func compare(_ pixels: PlanePixels, _ expected: [DoubleReference.Split]) {
    #expect(pixels.size.width*pixels.size.height == expected.count)
    for i in expected.indices {
        for c in 0..<3 {
            #expect(abs(code(Double(pixels.baseRGBA[i*4+c]))-code(expected[i].base[c])) <= 1)
            let actualHDR = Double(pixels.baseRGBA[i*4+c])*exp2(Double(pixels.gain[i*pixels.gainChannelCount+(pixels.gainChannelCount == 1 ? 0 : c)]))
            #expect(abs(code(actualHDR,hdr:true)-code(expected[i].base[c]*exp2(expected[i].gains[c]),hdr:true)) <= 1)
        }
        for c in 0..<3 {
            let actual = Double(pixels.gain[i*pixels.gainChannelCount+(pixels.gainChannelCount == 1 ? 0 : c)])
            #expect(abs(actual-expected[i].gains[c])*1023/3 <= 1)
        }
    }
}
private func cube(swap: Bool = false) -> String {
    var text = "TITLE \"Synthetic\"\nLUT_3D_SIZE 2\n"
    for b in 0...1 { for g in 0...1 { for r in 0...1 {
        text += swap ? "\(b) \(g) \(r)\n" : "\(r) \(g) \(b)\n"
    }}}
    return text
}
/// Identity over codes in [-2, 2], so a negative log toe is not clamped.
private func wideIdentity() -> String {
    var text = "LUT_3D_SIZE 2\nDOMAIN_MIN -2 -2 -2\nDOMAIN_MAX 2 2 2\n"
    for b in [-2, 2] { for g in [-2, 2] { for r in [-2, 2] { text += "\(r) \(g) \(b)\n" } } }
    return text
}
/// Halves every code. Fitted and unfitted encodings therefore leave the LUT apart.
private func wideHalf() -> String {
    var text = "LUT_3D_SIZE 2\nDOMAIN_MIN -2 -2 -2\nDOMAIN_MAX 2 2 2\n"
    for b in [-2.0, 2.0] { for g in [-2.0, 2.0] { for r in [-2.0, 2.0] {
        text += "\(r * 0.5) \(g * 0.5) \(b * 0.5)\n"
    } } }
    return text
}

@Suite(.serialized) struct AdjustmentTests {
    @Test func sdrExposureContractAndDefaultIdentity() async throws {
        let engine = try RenderEngine(), epsilon = 0.0001
        let xs = (0...32).map { Double($0)/32 } + [0.8,0.99,1-epsilon,1,1+epsilon]
        let source = try await engine.source(image:bitmap(xs.map { SIMD3(repeating:$0) },width:xs.count,height:1),domain:.sdr)
        let original = RenderEngine.readPixels(try await engine.render(source))
        let zero = RenderEngine.readPixels(try await engine.render(source,nodes:[AdjustmentNode(.exposure,value:0)]))
        #expect(zero.baseRGBA == original.baseRGBA)
        #expect(xs.allSatisfy { DoubleReference.point(SIMD3(repeating:$0),operation:.exposure,value:0,sdr:true).x == $0 })
        let defaults = RenderEngine.readPixels(try await engine.render(source,recipe:Recipe(inputDomain:.sdr)))
        #expect(zip(defaults.baseRGBA.prefix(33*4),original.baseRGBA.prefix(33*4)).allSatisfy { abs($0-$1)<0.000001 })
        for ev in [0.0001,0.5,1.0] {
            let output = RenderEngine.readPixels(try await engine.render(source,nodes:[AdjustmentNode(.exposure,value:Float(ev))]))
            let gpu = xs.indices.map { Double(output.baseRGBA[$0*4]) }
            let cpu = xs.map { DoubleReference.point(SIMD3(repeating:$0),operation:.exposure,value:ev,sdr:true).x }
            #expect(abs(code(gpu[33])-code(cpu[33])) <= 1)
            for curve in [gpu,cpu] {
                for i in xs.indices where xs[i] <= 1 {
                    #expect(curve[i] >= xs[i]-0.000001 && curve[i] <= 1.000001)
                }
                #expect(zip(curve.prefix(32),curve.dropFirst().prefix(32)).allSatisfy { $0 <= $1+0.000001 })
                #expect(abs(curve[36]-1)<0.000001 && curve[31]<1)
                if ev == 0.0001 {
                    #expect(abs(curve[33]-0.8)<0.0001)
                    #expect(abs(curve[34]-0.99*exp2(ev))<0.000001)
                } else {
                    let left = (curve[36]-curve[35])/epsilon, right = (curve[37]-curve[36])/epsilon
                    #expect(abs(left-right)<0.01 && abs(left)<0.01)
                }
            }
        }
        let negative = RenderEngine.readPixels(try await engine.render(source,nodes:[AdjustmentNode(.exposure,value:-1)]))
        for i in xs.indices { #expect(abs(Double(negative.baseRGBA[i*4])-xs[i]/2)<0.000001) }
        let hdr = SIMD3<Double>(2.4,1.6,0.8)
        let hdrSource = try await engine.source(image:bitmap([hdr],width:1,height:1),domain:.hdr)
        let hdrDefault = RenderEngine.readPixels(try await engine.render(hdrSource,recipe:Recipe(inputDomain:.hdr)))
        for c in 0..<3 { #expect(abs(Double(hdrDefault.baseRGBA[c])*exp2(Double(hdrDefault.gain[0]))-hdr[c])<0.00001) }
    }

    @Test func allDeclaredLUTSpacePairsRender() async throws {
        let engine = try RenderEngine(), lut = try ColorLUT(cube:cube())
        let image = bitmap([SIMD3(repeating:0.8)],width:1,height:1)
        let sdr = try await engine.source(image:image,domain:.sdr)
        let raw = try await engine.source(image:image,domain:.rawEDR)
        // One pixel/LUT/strength; use RAW only when S-Log3 input requires it.
        for input in Adjustments.declaration("look.input")!.options {
            let source = input.domains.contains(.sdr) ? sdr : raw
            for output in Adjustments.declaration("look.output")!.options {
                let recipe = Recipe(inputDomain:source.domain,look:LUTReference(contentHash:lut.contentHash,name:"Identity"),values:[
                    "look.input":.string(input.id),"look.output":.string(output.id),"hdr.range":.number(4),"hdr.coverage":.number(0)])
                let pixels = RenderEngine.readPixels(try await engine.render(source,recipe:recipe,lut:lut))
                #expect(pixels.baseRGBA.allSatisfy(\.isFinite) && pixels.gain.allSatisfy(\.isFinite))
                if input.id == "srgb" && output.id == "pq" { #expect(pixels.gain[0] > 0) }
            }
        }
    }

    @Test func recipeUnitsDefaultsAndLUTReference() async throws {
        for domain in InputDomain.allCases {
            let resolved = try RenderAdjustments(recipe:Recipe(inputDomain:domain))
            #expect(resolved.hdr.source == HDRSource.defaultSource(for:domain))
            #expect(resolved.hdr.range == nil && resolved.hdr.expansionStart == nil)
            #expect(resolved.tone.contrast == 1 && resolved.hdr.strength == 1)
        }
        let rawRecipe = Recipe(inputDomain:.rawEDR,values:["color.warmth":.number(50),
            "develop.tint":.number(35),"develop.luminanceNR":.number(40),"develop.sharpness":.number(25)])
        let raw = try SourceOptions(recipe:rawRecipe)
        #expect(raw.raw.tint == 35 && raw.raw.luminanceNR == 0.4 && raw.raw.sharpness == 0.25)
        #expect(raw.raw.temperature == nil && raw.raw.colorNR == nil)
        #expect(try RenderAdjustments(recipe:rawRecipe).color.warmth == 0)
        #expect(SourceOptions.parameters == Adjustments.all.filter { $0.cost == .redevelop })
        #expect(AdjustmentNode.parameters == AdjustmentNode.parameterIDs.map { Adjustments.declaration($0)! })
        let lut = try ColorLUT(cube:cube(swap:true))
        #expect(lut == (try ColorLUT(cube:cube(swap:true))))
        let recipe = Recipe(inputDomain:.hdr,look:LUTReference(contentHash:lut.contentHash,name:"Synthetic"),values:[
            "tone.contrast":.number(-100),"tone.highlights":.number(-40),"color.saturation":.number(-50),
            "hdr.strength":.number(80),"hdr.range":.number(3),"hdr.expansionStart":.number(25),
            "look.input":.string("p3"),"look.output":.string("p3"),"look.strength":.number(70)])
        let edit = try RenderAdjustments(recipe:recipe,lut:lut)
        #expect(edit.tone.contrast == 0.625 && edit.tone.highlights == -0.4)
        #expect(edit.color.saturation == -0.5 && edit.hdr.strength == 0.8)
        #expect(edit.hdr.expansionStart == 0.25 && edit.look.strength == 0.7)
        let engine = try RenderEngine(), rgb = SIMD3<Double>(4,2,1)
        let source = try await engine.source(image:bitmap([rgb],width:1,height:1),domain:.hdr)
        let actual = RenderEngine.readPixels(try await engine.render(source,recipe:recipe,lut:lut))
        compare(actual,[DoubleReference.hdrOutput(DoubleReference.prepare(rgb,settings:edit,sdr:false),
            settings:edit.hdr,range:3,shoulder:false,allowRolloff:true)])
        let rawSource = try await engine.source(image:bitmap([rgb],width:1,height:1),domain:.rawEDR)
        do {
            _ = try await engine.render(rawSource,nodes:[AdjustmentNode(.warmth,value:0.1)])
            Issue.record("Non-RAW white balance node applied to RAW")
        } catch RenderError.invalidAdjustment {}
        do {
            _ = try RenderAdjustments(recipe:recipe,lut:ColorLUT(cube:cube()))
            Issue.record("Mismatched LUT contents accepted")
        } catch RenderError.invalidLUT {}
    }

    @Test func lutContentHashIsTheFileBytesIncludingAByteOrderMark() throws {
        let body = Data("LUT_1D_SIZE 2\r\n0 0 0\r\n1 .9 .8\r\n".utf8)
        let marked = Data([0xEF,0xBB,0xBF]) + body
        func sha(_ data: Data) -> String { "sha256:" + SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
        let lut = try ColorLUT(data:marked)
        #expect(lut.contentHash == sha(marked))
        #expect(lut.contentHash != (try ColorLUT(data:body)).contentHash)
        #expect(lut.values == (try ColorLUT(data:body)).values)
    }

    @Test func pointNodesAgainstDoubleAndToneAnchors() async throws {
        let engine = try RenderEngine()
        let values: [(AdjustmentOperation,Double)] = [(.exposure,0.7),(.contrast,65),(.highlights,-70),
            (.shadows,70),(.blacks,-60),(.warmth,35),(.tint,-25),(.vibrance,45),(.saturation,-100)]
        for (operation,value) in values {
            for (rgb,domain) in [(SIMD3<Double>(0.1,0.08,0.05),InputDomain.sdr),(SIMD3<Double>(2.4,1.8,1.2),.hdr)] {
                let source = try await engine.source(image:bitmap([rgb],width:1,height:1),domain:domain)
                let engineValue = Adjustments.declaration(operation.parameterID)!.engineValue(value)
                let output = RenderEngine.readPixels(try await engine.render(source,nodes:[AdjustmentNode(operation,value:Float(engineValue))]))
                let changed = DoubleReference.point(rgb,operation:operation,value:engineValue,sdr:domain == .sdr)
                let reference = domain == .sdr ? DoubleReference.Split(base:changed,gain:0) : DoubleReference.sourceHDRSplit(changed)
                compare(output,[reference])
                if [.warmth,.tint,.vibrance,.saturation].contains(operation) {
                    #expect(abs(DoubleReference.luma(changed)-DoubleReference.luma(rgb)) < 0.000001)
                }
            }
        }
        let contrast: (Double) -> Double = { value in
            DoubleReference.point(SIMD3(repeating:value),operation:.contrast,value:1.6).x
        }
        #expect(abs(contrast(0.18)-0.18) < 1e-12)
        #expect(contrast(0) == 0 && contrast(1) == 1 && contrast(2) == 2)
        let epsilon = 0.00001
        #expect(abs((contrast(1)-contrast(1-epsilon))/epsilon-1) < 0.0001)
        for nativeContrast in [0.6,2.0] {
            let left = DoubleReference.grade(SIMD3(repeating:1-epsilon),contrast:nativeContrast).x
            let right = DoubleReference.grade(SIMD3(repeating:1+epsilon),contrast:nativeContrast).x
            #expect(abs((1-left)/epsilon-1) < 0.0001)
            #expect(abs((right-1)/epsilon-1) < 0.0001)
        }
        for operation in [AdjustmentOperation.shadows,.blacks] {
            #expect(DoubleReference.point(SIMD3(repeating:0.5),operation:operation,value:1) == SIMD3(repeating:0.5))
        }
        let dark = DoubleReference.point(SIMD3(repeating:0),operation:.blacks,value:-0.6)
        #expect(dark.x > 0)
        let saturated = SIMD3<Double>(0.1,2,0.1)
        let source = try await engine.source(image:bitmap([saturated],width:1,height:1),domain:.hdr)
        var edit = RenderAdjustments()
        edit.color.saturation = 1; edit.hdr.range = 3
        let fitted = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        let expected = DoubleReference.prepare(saturated,settings:edit,sdr:false)
        compare(fitted,[expected])
        let reconstructed = SIMD3(Double(fitted.baseRGBA[0]),Double(fitted.baseRGBA[1]),Double(fitted.baseRGBA[2]))*exp2(Double(fitted.gain[0]))
        #expect(abs(DoubleReference.luma(reconstructed)-DoubleReference.luma(saturated)) < 0.0001)
    }

    @Test func perceptualContrastAndHighlightsStrength() async throws {
        let engine = try RenderEngine()
        let xs = (0...256).map { Double($0)/256 } + [1.5]
        let source = try await engine.source(image: bitmap(xs.map { SIMD3(repeating: $0) }, width: xs.count, height: 1), domain: .hdr)
        for operation in [AdjustmentOperation.contrast, .highlights] {
            for amount in [-100.0, 100.0] {
                let value = operation == .contrast ? ParameterDeclaration.contrastMultiplier(for: amount) : amount/100
                let pixels = RenderEngine.readPixels(try await engine.render(source, nodes: [AdjustmentNode(operation, value: Float(value))]))
                let expected = xs.map { DoubleReference.point(SIMD3(repeating: $0), operation: operation, value: value).x }
                #expect(zip(expected, expected.dropFirst()).allSatisfy { $0 <= $1 })
                for i in xs.indices {
                    let rendered = Double(pixels.baseRGBA[i*4]) * exp2(Double(pixels.gain[i*pixels.gainChannelCount]))
                    #expect(abs(rendered - expected[i]) < 0.00002)
                }
            }
        }
        let contrast = DoubleReference.point(SIMD3(repeating: 0.5), operation: .contrast, value: 1.6).x
        let dark = DoubleReference.point(SIMD3(repeating: 0.05), operation: .contrast, value: 1.6).x
        #expect(log2(contrast/0.5) > 0.4 && log2(contrast/0.5) < 0.5)
        #expect(log2(dark/0.05) > -1 && log2(dark/0.05) < -0.7)
        let highlight = DoubleReference.point(SIMD3(repeating: 0.6), operation: .highlights, value: 1).x
        #expect(log2(highlight/0.6) > 0.4 && log2(highlight/0.6) < 0.5)
    }

    @Test func highlightsJoinSmoothlyAcrossSDRWhite() async throws {
        let epsilon = 1e-6
        let xs = [1-epsilon, 1, 1+epsilon, 2-epsilon, 2, 2+epsilon, 3]
        let engine = try RenderEngine()
        let source = try await engine.source(image: bitmap(xs.map { SIMD3(repeating: $0) }, width: xs.count, height: 1), domain: .hdr)
        for amount in [-1.0, 1.0] {
            let ys = xs.map { DoubleReference.point(SIMD3(repeating: $0), operation: .highlights, value: amount).x }
            let left = (ys[1]-ys[0])/epsilon, right = (ys[2]-ys[1])/epsilon
            #expect(abs(left-right) < 0.0002)
            #expect(abs(right-(amount < 0 ? 1 : exp2(-3*amount))) < 0.0002)
            #expect(abs((ys[5]-ys[4])/epsilon-exp2(2*amount)) < 0.0002)
            #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 })
            if amount < 0 {
                for value in stride(from: 0.0, through: 4.0, by: 0.01) {
                    #expect(DoubleReference.point(SIMD3(repeating: value), operation: .highlights, value: amount).x <= value+1e-12)
                }
            }
            let pixels = RenderEngine.readPixels(try await engine.render(source, nodes: [AdjustmentNode(.highlights, value: Float(amount))]))
            for i in xs.indices {
                let actual = Double(pixels.baseRGBA[i*4]) * exp2(Double(pixels.gain[i*pixels.gainChannelCount]))
                #expect(abs(actual-ys[i]) < 0.00002)
            }
        }
    }

    @Test func whitesCrossesWhiteWithoutClipping() async throws {
        let xs = (0...64).map { Double($0)/32 }
        let engine = try RenderEngine()
        for domain in [InputDomain.sdr, .hdr] {
            let source = try await engine.source(image: bitmap(xs.map { SIMD3(repeating: $0) }, width: xs.count, height: 1), domain: domain)
            for amount: Float in [-1, 0, 1] {
                var edit = RenderAdjustments()
                edit.tone.whites = amount
                edit.hdr.coverage = 0
                edit.hdr.range = 4
                let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
                let reference = xs.map { DoubleReference.point(SIMD3(repeating: $0), operation: .whites, value: Double(amount)).x }
                #expect(zip(reference, reference.dropFirst()).allSatisfy { $0 <= $1 })
                for i in xs.indices {
                    let actual = Double(pixels.baseRGBA[i*4]) * exp2(Double(pixels.gain[i*pixels.gainChannelCount]))
                    // SDR fixtures contain only values up to white; HDR also exercises the extension.
                    if domain == .hdr || xs[i] <= 1 { #expect(abs(actual - reference[i]) < 0.00005) }
                }
                #expect(pixels.baseRGBA[0] == 0)
                if amount == 1 { #expect(pixels.gain[32*pixels.gainChannelCount] > 0.99) }
                if amount == 1 {
                    edit.hdr.range = 0.5
                    let limited = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
                    let white = Double(limited.baseRGBA[32*4]) * exp2(Double(limited.gain[32*limited.gainChannelCount]))
                    #expect(white <= exp2(0.5))
                }
            }
        }
    }

    @Test func whitesStartsContinuouslyWithExistingSDRColourOverflow() async throws {
        let rgb = SIMD3<Double>(0.95,0.70,0.65), engine = try RenderEngine()
        let source = try await engine.source(image: bitmap([rgb], width: 1, height: 1), domain: .sdr)
        let lut = try ColorLUT(cube: cube())
        for strength in [0.0, 0.5] {
            var previous: PlanePixels?
            for whites: Float in [0, 0.0001, -0.0001] {
                var edit = RenderAdjustments()
                edit.color.warmth = 1; edit.tone.whites = whites
                edit.hdr.coverage = 0; edit.hdr.range = 4
                if strength > 0 { edit.look.lut = lut; edit.look.strength = Float(strength) }
                let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
                compare(pixels, [DoubleReference.prepare(rgb, settings: edit, sdr: true)])
                if let zero = previous {
                    for c in 0..<3 { #expect(abs(pixels.baseRGBA[c]-zero.baseRGBA[c]) < 0.001) }
                    #expect(abs(pixels.gain[0]-zero.gain[0]) < 0.001)
                } else {
                    #expect(pixels.gain[0] == 0)
                    previous = pixels
                }
            }
        }
    }

    @Test func sdrCurveShapesMidtonesAndKeepsHDR() async throws {
        let curve = try ToneCurve([0,0, 0.25,0.16, 0.5,0.5, 0.75,0.84, 1,1])
        let xs = [0.0, 0.05, 0.18, 0.5, 0.9, 1, 1.5]
        #expect(DoubleReference.toneCurve(SIMD3(repeating: 0.5), curve: curve).x > 0.5)
        #expect(DoubleReference.toneCurve(SIMD3(repeating: 0.05), curve: curve).x < 0.05)
        #expect(DoubleReference.toneCurve(SIMD3(repeating: 1.5), curve: curve).x == 1.5)
        #expect(DoubleReference.toneCurve(SIMD3(repeating: 0.18), curve: ToneCurve()).x == 0.18)
        let engine = try RenderEngine()
        let source = try await engine.source(image: bitmap(xs.map { SIMD3(repeating: $0) }, width: xs.count, height: 1), domain: .hdr)
        // A 1D look shares the table buffer with the baked tone curve.
        let identity = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        for lut in [nil, identity] {
            var recipe = Recipe(inputDomain: .hdr)
            recipe.setValue(curve.parameterValue, for: "tone.curve")
            recipe.setValue(.number(4), for: "hdr.range")
            if let lut { recipe.look = LUTReference(contentHash: lut.contentHash, name: "Identity") }
            let pixels = RenderEngine.readPixels(try await engine.render(source, recipe: recipe, lut: lut))
            for i in xs.indices {
                let actual = Double(pixels.baseRGBA[i*4]) * exp2(Double(pixels.gain[i*pixels.gainChannelCount]))
                let expected = DoubleReference.toneCurve(SIMD3(repeating: xs[i]), curve: curve).x
                #expect(abs(actual - expected) < 0.0001)
            }
        }
    }

    @Test func analyticExpansionMasksAndFixedScaleCache() async throws {
        let engine = try RenderEngine(), width = 16, height = 12
        let values = (0..<(width*height)).map { i -> SIMD3<Double> in
            let y = (i%width > 9 && i/width > 3) ? 0.92 : 0.06
            return SIMD3(y,y*0.8,y*0.7)
        }
        let source = try await engine.source(image:bitmap(values,width:width,height:height),domain:.sdr)
        var edit = RenderAdjustments()
        edit.hdr.coverage = 0.35
        let actual = try await engine.analysis(source,adjustments:edit)
        let reference = DoubleReference.spatialAnalysis(values,size:source.size,settings:edit,sdr:true)
        let gain = RenderEngine.readTexture(actual.expansion)
        for (a,b) in zip(gain,reference.expansion) {
            #expect(abs(Int((Double(a)*1023/3).rounded())-Int((b*1023/3).rounded())) <= 1)
        }
        let masks = RenderEngine.readTexture(actual.masks)
        for i in reference.masks.indices { for c in 0..<4 { #expect(abs(Double(masks[i*4+c])-reference.masks[i][c]) < 0.00001) } }
        let automatic = 0.5+2.5*DoubleReference.smoothStep(0.5,1,reference.peaks.y)
        let output = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        let expected = values.indices.map { i in
            DoubleReference.hdrOutput(DoubleReference.prepare(values[i],settings:edit,sdr:true),
                expansion:reference.expansion[i]*automatic/3,settings:edit.hdr,range:automatic,shoulder:false,allowRolloff:false)
        }
        compare(output,expected)
        #expect((gain.max() ?? 0) > 0)
        edit.hdr.strength = 0.7; edit.hdr.range = 2
        let reused = try await engine.analysis(source,adjustments:edit)
        #expect(reused.expansion === actual.expansion)
        let sized = PixelSize(width:23,height:17)
        let full = RenderEngine.readPixels(try await engine.render(source,adjustments:edit,size:sized))
        let region = CGRect(x:3,y:2,width:7,height:6)
        let roiPlanes = try await engine.render(source,adjustments:edit,size:sized,region:region)
        let roi = RenderEngine.readPixels(roiPlanes)
        #expect(roiPlanes.region == region && roi.size == PixelSize(width:7,height:6))
        for y in 0..<6 { for x in 0..<7 {
            let cropped = y*7+x, fullIndex = (y+2)*23+x+3
            #expect(abs(roi.gain[cropped]-full.gain[fullIndex]) < 0.00001)
            for c in 0..<4 { #expect(abs(roi.baseRGBA[cropped*4+c]-full.baseRGBA[fullIndex*4+c]) < 0.00001) }
        } }
        do {
            _ = try await engine.render(source,recipe:Recipe(inputDomain:.sdr),size:sized,region:CGRect(x:-1,y:0,width:1,height:1))
            Issue.record("Accepted an out-of-bounds ROI")
        } catch RenderError.invalidRegion {}
        let stripes = StripeCollector()
        try await engine.renderStripes(source,adjustments:edit,size:sized,rows:5) { stripes.append($0) }
        #expect(zip(full.baseRGBA,stripes.base).allSatisfy { abs($0-$1)<0.00001 })
        #expect(zip(full.gain,stripes.gain).allSatisfy { abs($0-$1)<0.00001 })
    }

    @Test func hdrOnlyBaseInvariantSoftShoulderAndSDRRolloff() async throws {
        let engine = try RenderEngine()
        let values: [SIMD3<Double>] = [SIMD3(0.2,0.18,0.12),SIMD3(4,3,2),SIMD3(16,12,8),SIMD3(7,5,3)]
        let source = try await engine.source(image:bitmap(values,width:4,height:1),domain:.hdr)
        var edit = RenderAdjustments()
        let baseline = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        let reference = values.map { rgb in
            DoubleReference.hdrOutput(DoubleReference.prepare(rgb,settings:edit,sdr:false),settings:edit.hdr,
                range:4,shoulder:false,allowRolloff:true)
        }
        compare(baseline,reference)
        #expect(abs(Double(baseline.baseRGBA[8])*exp2(Double(baseline.gain[2]))-16) < 0.0001)
        var dimmed = edit
        dimmed.tone.exposure = -1
        let dimmedAnalysis = try await engine.analysis(source,adjustments:dimmed)
        #expect(try await engine.graphConfiguration(source,dimmed,analysis:dimmedAnalysis).range == 4)
        let rawSource = try await engine.source(image:bitmap(values,width:4,height:1),domain:.rawEDR)
        let generated = RenderEngine.readPixels(try await engine.render(rawSource,adjustments:edit))
        #expect(Double(generated.baseRGBA[8])*exp2(Double(generated.gain[2])) < 8)
        edit.hdr.range = 3
        let limited = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(Double(limited.baseRGBA[8])*exp2(Double(limited.gain[2])) < 8)
        edit.hdr.strength = 0.6; edit.hdr.range = 1.5
        let changed = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(changed.baseRGBA == baseline.baseRGBA)
        edit.hdr.sdrRolloff = 0.8
        let rolloff = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        for i in values.indices { for c in 0..<3 {
            let a = Double(rolloff.baseRGBA[i*4+c])*exp2(Double(rolloff.gain[i]))
            let b = Double(changed.baseRGBA[i*4+c])*exp2(Double(changed.gain[i]))
            #expect(abs(a-b) < 0.00002)
        }}
        let repeated = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        let other = try RenderEngine()
        let otherSource = try await other.source(image:bitmap(values,width:4,height:1),domain:.hdr)
        let newContext = RenderEngine.readPixels(try await other.render(otherSource,adjustments:edit))
        #expect(repeated.baseRGBA == rolloff.baseRGBA && newContext.baseRGBA == rolloff.baseRGBA)
        #expect(repeated.gain == rolloff.gain && newContext.gain == rolloff.gain)
        edit.hdr.enabled = false
        let sdr = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(sdr.gain.allSatisfy { $0 == 0 })
        #expect(sdr.baseRGBA == rolloff.baseRGBA)
    }

    @Test func cubeLUTSDRAndHDRSpacesAgainstDouble() async throws {
        let engine = try RenderEngine()
        let values = [SIMD3<Double>(2.4,1.6,0.8),SIMD3<Double>(0.3,0.2,0.1)]
        let source = try await engine.source(image:bitmap(values,width:2,height:1),domain:.hdr)
        let original = RenderEngine.readPixels(try await engine.render(source,adjustments:RenderAdjustments()))
        var edit = RenderAdjustments()
        edit.look.lut = try ColorLUT(cube:cube(swap:true)); edit.look.input = .displayP3; edit.look.output = .displayP3
        edit.look.strength = 0.7
        let result = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        let reference = values.map { DoubleReference.prepare($0,settings:edit,sdr:false) }
        compare(result,reference)
        #expect(result.baseRGBA[0] != original.baseRGBA[0])
        func peak(_ p: PlanePixels, _ i: Int) -> Double {
            (0..<3).map { c in Double(p.baseRGBA[4*i+c])*exp2(Double(p.gain[i*p.gainChannelCount+(p.gainChannelCount == 1 ? 0 : c)])) }.max()!
        }
        #expect(peak(result,0) > 1)
        edit.look.strength = 1
        let fullStrength = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(abs(peak(fullStrength,0)-peak(original,0)) < 0.00001)
        edit.look.strength = 0
        let bypassed = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        compare(bypassed,values.map { DoubleReference.sourceHDRSplit($0) })
        edit.look.output = .pq; edit.look.strength = 0.05
        let amplified = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        var fullEdit = edit; fullEdit.look.strength = 1
        let endpoints = values.map { DoubleReference.prepare($0,settings:fullEdit,sdr:false) }
        for i in values.indices { for c in 0..<3 {
            let oldBase = original.baseRGBA[i*4+c], oldHDR = oldBase*exp2(original.gain[i])
            let full = endpoints[i], expectedBase = oldBase+(Float(full.base[c])-oldBase)*edit.look.strength
            let expectedHDR = oldHDR+(Float(full.base[c]*exp2(full.gains[c]))-oldHDR)*edit.look.strength
            #expect(abs(amplified.baseRGBA[i*4+c]-expectedBase) < 1e-5)
            #expect(abs(amplified.baseRGBA[i*4+c]*exp2(amplified.gain[i*3+c])-expectedHDR) < 1e-4)
        } }
        // This swap brightens blue; red's completed HDR/SDR ratio can remain
        // exactly unchanged. The endpoint oracle above checks every channel.
        #expect(amplified.gain.prefix(3).contains { $0 > original.gain[0]+1e-4 })
        edit.look.strength = 0
        let hdrOutputBypass = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(hdrOutputBypass.baseRGBA == original.baseRGBA && hdrOutputBypass.gain == original.gain)
        edit.look.lut = try ColorLUT(cube:cube()); edit.look.input = .pq; edit.look.output = .pq; edit.look.strength = 0.5
        let pq = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        compare(pq,values.map { DoubleReference.prepare($0,settings:edit,sdr:false) })
        let oneD = try ColorLUT(cube:"LUT_1D_SIZE 2\nDOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 2 2 2\n0.1 0.2 0.3\n0.8 0.9 1.0\n")
        #expect(!oneD.is3D && oneD.domainMinimum.x == -1)
        edit.look.lut = oneD; edit.look.input = .sRGB; edit.look.output = .rec709; edit.look.strength = 0.4
        let graded = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        compare(graded,values.map { DoubleReference.prepare($0,settings:edit,sdr:false) })
    }

    @Test func editedAuthoredThreeChannelOffsetsAndWholeEditEndpoints() async throws {
        let engine = try RenderEngine()
        let b = SIMD3<Double>(0.2,0.4,0.6), g = SIMD3<Double>(1,1.5,3.72), o = SIMD3<Double>(repeating:1/64)
        let hdr = DoubleReference.reconstruct(b,gain:g,baseOffset:o,alternateOffset:o)
        let baseSource = try await engine.source(image:bitmap([b],width:1,height:1),domain:.sdr)
        let gainSource = try await engine.source(image:bitmap([g/3.72],width:1,height:1),domain:.sdr)
        var tags = ["HDRToneMap:BaseColorIsWorkingColor":"True", "HDRToneMap:AlternateHeadroom":"3.72"]
        for c in 0..<3 {
            let prefix = "HDRToneMap:ChannelMetadata[\(c)]."
            for (key,value) in [("GainMapMin","0"),("GainMapMax","3.72"),("Gamma","1"),("BaseOffset","0.015625"),("AlternateOffset","0.015625")] { tags[prefix+key] = value }
        }
        let original = AuthoredGainMap(standard:.iso,auxiliaryInfo:tags as NSDictionary,image:gainSource.hdrImage,
            channelCount:3,baseColorSpace:RenderEngine.workingColorSpace,alternateColorSpace:nil,auxiliaryColorSpace:nil,tags:tags)
        let source = RenderSource(id:UUID(),renderID:UUID(),origin:nil,domain:.dual,size:baseSource.size,nativeSize:baseSource.nativeSize,authoredGainMap:original,
            hdrImage:bitmap([hdr],width:1,height:1),authoredBaseImage:baseSource.hdrImage,rawSettings:nil,
            texture:baseSource.texture,baseSpace:RenderEngine.workingColorSpace,gainTexture:gainSource.texture)
        var edit = RenderAdjustments()
        let untouched = try await engine.render(source,recipe:Recipe(inputDomain:.dual))
        #expect(untouched.provenance == .authored)
        edit.hdr.coverage = 0.5
        let automatic = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        for c in 0..<3 { #expect(abs(Double(automatic.gain[c])-g[c]) < 0.00001) }
        let sourceAnalysis = try await engine.analysis(source)
        #expect(abs(sourceAnalysis.sourceHeadroom-3.72) < 0.00001)
        #expect(abs(try await engine.graphConfiguration(source,edit,analysis:sourceAnalysis).range-3.72) < 0.00001)
        edit.hdr.strength = 0.4; edit.hdr.range = 3
        let changed = try await engine.render(source,adjustments:edit)
        #expect(changed.base === untouched.base)
        #expect(changed.provenance == .editedAuthored && changed.gainChannelCount == 3)
        let actual = RenderEngine.readPixels(changed)
        let expected = DoubleReference.authoredGain(base:b,gain:g,baseOffset:o,alternateOffset:o,strength:0.4,range:3,shoulder:false)
        for c in 0..<3 { #expect(abs(Double(actual.gain[c])-expected[c]) < 0.00001) }
        if case .isoLog2(let metadata) = changed.encoding { #expect(metadata.baseOffset == SIMD3(repeating:Float(1.0/64))) }
        else { Issue.record("Missing ISO edited-pair metadata") }
        let displayChanged = try await engine.displayPair(changed,source:source)
        #expect(displayChanged.gain === changed.gain && displayChanged.gainChannelCount == 3)
        #expect(displayChanged.baseOffset == SIMD3(repeating:Float(1.0/64)))
        var lookOnly = RenderAdjustments()
        lookOnly.look.lut = try ColorLUT(cube:cube(swap:true))
        lookOnly.look.input = .displayP3; lookOnly.look.output = .displayP3
        let looked = try await engine.render(source,adjustments:lookOnly)
        #expect(looked.provenance == .resplit && looked.gainChannelCount == 3)
        if case .pairedLog2 = looked.encoding {} else { Issue.record("SDR LUT lost its edited endpoint pair") }
        edit.tone.exposure = 0.3
        let resplit = try await engine.render(source,adjustments:edit)
        #expect(resplit.provenance == .resplit && resplit.gainChannelCount == 3)
    }

    @Test func cachedFrameTiming2560() async throws {
        let engine = try RenderEngine(), width = 2560, height = 1707
        let input = (0..<(width*height)).map { index -> SIMD3<Double> in
            let v = 0.05+3.95*Double(index%width)/Double(width-1)
            return SIMD3(v*0.8,v,v*0.6)
        }
        let source = try await engine.source(image:bitmap(input,width:width,height:height),domain:.rawEDR)
        var edit = RenderAdjustments()
        edit.tone.exposure = 0.3; edit.tone.contrast = Float(Adjustments.declaration("tone.contrast")!.engineValue(25)); edit.tone.highlights = -0.2
        edit.color.vibrance = 0.2; edit.hdr.source = .capturedExpand
        let analysisStart = DispatchTime.now().uptimeNanoseconds
        _ = try await engine.analysis(source,adjustments:edit)
        let analysisMilliseconds = Double(DispatchTime.now().uptimeNanoseconds-analysisStart)/1e6
        var timings: [Double] = []
        var lastFrame: RenderPlanes?
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            lastFrame = try await engine.render(source,adjustments:edit)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
        }
        let displayStart = DispatchTime.now().uptimeNanoseconds
        _ = try await engine.displayPair(try #require(lastFrame),source:source)
        let displayMilliseconds = Double(DispatchTime.now().uptimeNanoseconds-displayStart)/1e6
        print("P7-2b normalize 2560x1707 ms=\(displayMilliseconds)")
        print("P7-1a cached 2560x1707 median_ms=\(timings.sorted()[1]) min_ms=\(timings.min()!) max_ms=\(timings.max()!) analysis_ms=\(analysisMilliseconds)")
    }

    @Test func logCurvesMatchWhitePaperAndRoundTrip() {
        let spaces: [(LUTSpace, Double, Double)] = [
            (.sLog3, 420.0/1023, 95.0/1023),
            (.slog3SGamut3, 420.0/1023, 95.0/1023),
            (.vlogVGamut, 0.4233114488, 0.125),
            (.flog2FGamut, 0.3910072419, 0.092864),
            (.logC3AWG3, 0.3910068320, 0.092809),
            (.logC4AWG4, 0.2783958365, 95.0/1023),
            (.clog3CinemaGamut, 0.3433893704, 0.12512219),
            (.flogFGamut, 0.4593184587, 0.092864),
            (.flog2cFGamutC, 0.3910072419, 0.092864),
            (.appleLogRec2020, 0.4882724585, 0.1504764523),
            (.nlogRec2020, 0.3636678832, 0.1243726159),
            (.dlogDGamut, 0.3987645562, 0.0929),
            (.clog2CinemaGamut, 0.3982546940, 0.092864125),
            (.davinciDWG, 0.3360432724, 0),
            (.acescctAP1, 0.4135884025, 0.0729055342)]
        let samples = [-0.2, -0.02, 0, 0.001, 0.01125, 0.05, 0.18, 0.9, 1, 4]
        let color = SIMD3<Double>(-0.15, 0.4, 1.1)
        for (space, gray, black) in spaces {
            let encodedGray = DoubleReference.encodeLUT(SIMD3(repeating: 0.18), space: space).x
            let encodedBlack = DoubleReference.encodeLUT(.zero, space: space).x
            #expect(abs(encodedGray - gray) < 1e-6, "space \(space.rawValue) 18%")
            #expect(abs(encodedBlack - black) < 1e-6, "space \(space.rawValue) black")
            for sample in samples where space != .appleLogRec2020 || sample >= -0.05641088 {
                let back = DoubleReference.decodeLUT(DoubleReference.encodeLUT(SIMD3(repeating: sample), space: space), space: space)
                #expect(back.x.isFinite && abs(back.x - sample) < 1e-5, "space \(space.rawValue) \(sample)")
            }
            let back = DoubleReference.decodeLUT(DoubleReference.encodeLUT(color, space: space), space: space)
            #expect(back.x.isFinite && back.y.isFinite && back.z.isFinite)
            for c in 0..<3 { #expect(abs(back[c] - color[c]) < 1e-4, "space \(space.rawValue) chromatic") }
        }
        // S-Log3 and S-Gamut3 share the curve; only the primaries differ, and neutrals are preserved.
        let cine = DoubleReference.encodeLUT(SIMD3(0.2, 0.5, 0.1), space: .sLog3)
        let gamut = DoubleReference.encodeLUT(SIMD3(0.2, 0.5, 0.1), space: .slog3SGamut3)
        #expect(cine != gamut)
    }

    @Test func logInputSkipsP3FitUntilAfterTheMix() async throws {
        let names = ["srgb","p3","rec709","hlg","pq","slog3-sgamut3cine","slog3-sgamut3","vlog-vgamut","flog2-fgamut","logc3-awg3","logc4-awg4","clog3-cinemagamut"]
        let lut = try ColorLUT(cube: cube())
        for (index, name) in names.enumerated() {
            let domain: InputDomain = index >= 5 ? .rawEDR : .sdr
            let recipe = Recipe(inputDomain: domain, look: LUTReference(contentHash: lut.contentHash, name: "Identity"), values: [
                "look.input": .string(name), "look.output": .string(name)])
            let edit = try RenderAdjustments(recipe: recipe, lut: lut)
            #expect(edit.look.input.rawValue == UInt32(index) && edit.look.input.isLog == (index >= 5))
        }
        #expect(throws: RenderError.self) {
            _ = try RenderAdjustments(recipe: Recipe(inputDomain: .sdr, look: LUTReference(contentHash: lut.contentHash, name: "Identity"), values: [
                "look.input": .string("flog2-fgamut"), "look.output": .string("srgb")]), lut: lut)
        }

        let outside = SIMD3<Double>(-0.3, 0.25, 1.4)
        let inside = SIMD3<Double>(0.2, 0.45, 0.7)
        let engine = try RenderEngine()
        let source = try await engine.source(image: bitmap([outside, inside], width: 2, height: 1), domain: .rawEDR)
        let identity = try ColorLUT(cube: wideIdentity())
        let half = try ColorLUT(cube: wideHalf())
        let spaces: [LUTSpace] = [.sLog3, .slog3SGamut3, .vlogVGamut, .flog2FGamut, .logC3AWG3, .logC4AWG4, .clog3CinemaGamut,
            .flogFGamut, .flog2cFGamutC, .appleLogRec2020, .nlogRec2020, .dlogDGamut, .clog2CinemaGamut, .davinciDWG, .acescctAP1]
        for space in spaces {
            var edit = RenderAdjustments()
            edit.look.lut = half
            edit.look.input = space
            edit.look.output = space
            edit.look.strength = 1
            let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            compare(pixels, [outside, inside].map { DoubleReference.prepare($0, settings: edit, sdr: false) })
            #expect(pixels.baseRGBA.allSatisfy { $0 >= -1e-4 }, "space \(space.rawValue) output stays non-negative")
            let fitted = DoubleReference.fitP3(outside, upper: max(1, outside.x, outside.y, outside.z))
            let skipped = DoubleReference.prepare(outside, settings: edit, sdr: false)
            let crushed = DoubleReference.prepare(fitted, settings: edit, sdr: false)
            let skippedHDR = skipped.base * exp2(skipped.gain)
            let crushedHDR = crushed.base * exp2(crushed.gain)
            #expect((0..<3).contains { abs(skippedHDR[$0] - crushedHDR[$0]) > (space == .clog2CinemaGamut ? 1e-5 : 0.01) }, "space \(space.rawValue) log input kept the unfitted pixel")

            edit.look.lut = identity
            edit.look.strength = 1
            let round = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            compare(round, [outside, inside].map { DoubleReference.prepare($0, settings: edit, sdr: false) })
            #expect(round.baseRGBA.allSatisfy { $0 >= -1e-4 })
        }
    }
}
private final class StripeCollector: @unchecked Sendable {
    var base: [Float] = [], gain: [Float] = []
    func append(_ output: RenderPlanes) { let p = RenderEngine.readPixels(output); base += p.baseRGBA; gain += p.gain }
}
