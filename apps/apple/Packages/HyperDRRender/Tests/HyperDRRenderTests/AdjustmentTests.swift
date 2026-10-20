import Foundation
import CoreImage
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
            let actualHDR = Double(pixels.baseRGBA[i*4+c])*exp2(Double(pixels.gain[i]))
            #expect(abs(code(actualHDR,hdr:true)-code(expected[i].base[c]*exp2(expected[i].gain),hdr:true)) <= 1)
        }
        #expect(abs(Int((Double(pixels.gain[i])*1023/3).rounded())-Int((expected[i].gain*1023/3).rounded())) <= 1)
    }
}
private func cube(swap: Bool = false) -> String {
    var text = "TITLE \"Synthetic\"\nLUT_3D_SIZE 2\n"
    for b in 0...1 { for g in 0...1 { for r in 0...1 {
        text += swap ? "\(b) \(g) \(r)\n" : "\(r) \(g) \(b)\n"
    }}}
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
            let source = input.id == "slog3-sgamut3cine" ? raw : sdr
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
        // L1 properties use the GPU's unedited pair, independently of the CPU grade.
        #expect(result.gain == original.gain)
        #expect(result.baseRGBA[0] != original.baseRGBA[0])
        for i in values.indices {
            for c in 0..<3 {
                let oldHDR = Double(original.baseRGBA[i*4+c])*exp2(Double(original.gain[i]))
                let newHDR = Double(result.baseRGBA[i*4+c])*exp2(Double(result.gain[i]))
                #expect(abs(newHDR/Double(result.baseRGBA[i*4+c])-oldHDR/Double(original.baseRGBA[i*4+c])) < 0.000001)
            }
        }
        edit.look.strength = 1
        let fullStrength = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(fullStrength.gain == original.gain)
        edit.look.strength = 0
        let bypassed = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        compare(bypassed,values.map { DoubleReference.sourceHDRSplit($0) })
        edit.look.output = .pq; edit.look.strength = 0.05
        let amplified = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        let amplifiedReference = values.map { value -> DoubleReference.Split in
            let pair = DoubleReference.sourceHDRSplit(value)
            let changedBase = DoubleReference.look(pair.base,settings:edit.look)
            return DoubleReference.sourceHDRSplit(changedBase*exp2(pair.gain))
        }
        compare(amplified,amplifiedReference)
        #expect(amplified.gain[0] > original.gain[0])
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

    @Test func editedAuthoredThreeChannelOffsetsAndWholeEditResplit() async throws {
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
        let source = RenderSource(id:UUID(),domain:.dual,size:baseSource.size,authoredGainMap:original,
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
        var lookOnly = RenderAdjustments()
        lookOnly.look.lut = try ColorLUT(cube:cube(swap:true))
        lookOnly.look.input = .displayP3; lookOnly.look.output = .displayP3
        let looked = try await engine.render(source,adjustments:lookOnly)
        #expect(looked.provenance == .resplit && looked.gainChannelCount == 1)
        if case .log2 = looked.encoding {} else { Issue.record("SDR LUT retained authored ISO encoding") }
        edit.tone.exposure = 0.3
        let resplit = try await engine.render(source,adjustments:edit)
        #expect(resplit.provenance == .resplit && resplit.gainChannelCount == 1)
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
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await engine.render(source,adjustments:edit)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
        }
        print("P7-1a cached 2560x1707 median_ms=\(timings.sorted()[1]) min_ms=\(timings.min()!) max_ms=\(timings.max()!) analysis_ms=\(analysisMilliseconds)")
    }
}
private final class StripeCollector: @unchecked Sendable {
    var base: [Float] = [], gain: [Float] = []
    func append(_ output: RenderPlanes) { let p = RenderEngine.readPixels(output); base += p.baseRGBA; gain += p.gain }
}
