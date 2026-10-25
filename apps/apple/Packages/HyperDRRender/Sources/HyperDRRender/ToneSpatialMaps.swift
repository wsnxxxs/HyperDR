import Foundation
import Metal
import HyperDRRecipe

struct ToneSpatialKey: Equatable {
    var source: UUID
    var tone: ToneAdjustments
    var color: ColorAdjustments
}
struct ToneSpatialMap {
    let id = UUID()
    let size: PixelSize
    let air: SIMD3<Float>
    let values: [SIMD4<Float>]
}
private struct ToneAreaSampling { var output, source, options: SIMD4<UInt32> }

extension RenderEngine {
    func toneSpatialMap(_ source: RenderSource, edit: RenderAdjustments) throws -> ToneSpatialMap? {
        guard edit.tone.dehaze != 0 || edit.tone.clarity != 0 else { return nil }
        var keyTone = ToneAdjustments()
        keyTone.exposure = edit.tone.exposure; keyTone.contrast = edit.tone.contrast
        keyTone.highlights = edit.tone.highlights; keyTone.shadows = edit.tone.shadows
        keyTone.whites = edit.tone.whites; keyTone.blacks = edit.tone.blacks
        // Transmission/air do not depend on strength. Only a simultaneous
        // clarity low frequency needs the actual dehaze rendition.
        keyTone.dehaze = edit.tone.dehaze == 0 ? 0 : (edit.tone.clarity == 0 ? 1 : edit.tone.dehaze)
        keyTone.clarity = edit.tone.clarity == 0 ? 0 : 1
        var keyColor = ColorAdjustments(); keyColor.warmth = edit.color.warmth; keyColor.tint = edit.color.tint
        let key = ToneSpatialKey(source: source.id,tone: keyTone,color: keyColor)
        if let cache = toneSpatialCache,cache.key == key { return cache.map }
        let fixed = try fixedAnalysisSource(source)
        let input = try workingInput(fixed), baseline = try lookBaseline(fixed,edit: edit)
        let ratio = min(1,768/Double(max(fixed.size.width,fixed.size.height)))
        let size = PixelSize(width: max(1,Int((Double(fixed.size.width)*ratio).rounded())),
                             height: max(1,Int((Double(fixed.size.height)*ratio).rounded())))
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let node = nodeContext(domain: fixed.domain,buffer: command)
        func sample(_ texture: any MTLTexture) throws -> any MTLTexture {
            let target = try node.texture(width: size.width,height: size.height)
            var p = ToneAreaSampling(output: SIMD4(UInt32(size.width),UInt32(size.height),0,0),
                source: SIMD4(UInt32(texture.width),UInt32(texture.height),0,0),options: SIMD4(1,0,0,0))
            try node.dispatch("sampleSourceArea",width: size.width,height: size.height,
                              textures: [texture,target,target],value: &p)
            return target
        }
        let sceneGrid = try sample(input), baseGrid = try sample(baseline)
        let exposed = try node.texture(width: size.width,height: size.height)
        let exposedBase = try node.texture(width: size.width,height: size.height)
        let temp = try node.texture(width: size.width,height: size.height)
        let rawDark = try node.texture(width: size.width,height: size.height)
        let dark = try node.texture(width: size.width,height: size.height)
        var estimate = edit; estimate.tone = keyTone; estimate.color = keyColor
        var p = graphUniform(fixed,estimate,size: size,region: CGRect(x: 0,y: 0,width: size.width,height: size.height))
        try node.dispatch("toneSpatialExpose",width: size.width,height: size.height,
            textures: [sceneGrid,baseGrid,exposed,exposedBase],value: &p)
        func minimum(_ input: any MTLTexture, _ output: any MTLTexture, context: RenderNodeContext) throws {
            var u = BoxUniform(radius: 7,vertical: 0,width: UInt32(size.width),height: UInt32(size.height))
            try context.dispatch("toneMinimum",width: size.width,height: size.height,textures: [input,temp],value: &u)
            u.vertical = 1
            try context.dispatch("toneMinimum",width: size.width,height: size.height,textures: [temp,output],value: &u)
        }
        var air = SIMD4<Float>(1,1,1,0)
        if keyTone.dehaze != 0 {
            try node.dispatch("toneDarkChannel",width: size.width,height: size.height,textures: [exposed,rawDark],value: &air)
            try minimum(rawDark,dark,context: node)
        }
        try finish(command)
        if keyTone.dehaze != 0 {
            let rgba = Self.readTexture(exposed), minima = Self.readTexture(dark)
            let rgb: [DoubleReference.RGB] = stride(from: 0,to: rgba.count,by: 4).map {
                .init(Double(rgba[$0]),Double(rgba[$0+1]),Double(rgba[$0+2]))
            }
            let atmosphere = DoubleReference.toneAtmosphere(rgb,dark: stride(from: 0,to: minima.count,by: 4).map { Double(minima[$0]) })
            air = SIMD4(Float(atmosphere.x),Float(atmosphere.y),Float(atmosphere.z),1)
        }
        guard let finishMap = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let context = nodeContext(domain: fixed.domain,buffer: finishMap)
        func texture() throws -> any MTLTexture { try context.texture(width: size.width,height: size.height) }
        let moments = try texture(), means = try texture(), coefficients = try texture(), smoothed = try texture()
        let transmission = try texture()
        var unused: UInt32 = 0
        func box(_ input: any MTLTexture, _ output: any MTLTexture) throws {
            var u = BoxUniform(radius: 8,vertical: 0,width: UInt32(size.width),height: UInt32(size.height))
            try context.dispatch("graphBox",width: size.width,height: size.height,textures: [input,temp],value: &u)
            u.vertical = 1
            try context.dispatch("graphBox",width: size.width,height: size.height,textures: [temp,output],value: &u)
        }
        if keyTone.dehaze != 0 {
            try context.dispatch("toneDarkChannel",width: size.width,height: size.height,textures: [exposed,rawDark],value: &air)
            try minimum(rawDark,dark,context: context)
            try context.dispatch("toneTransmissionMoments",width: size.width,height: size.height,
                textures: [exposed,dark,moments],value: &unused)
            try box(moments,means)
            try context.dispatch("toneTransmissionCoefficients",width: size.width,height: size.height,
                textures: [means,coefficients],value: &unused)
            try box(coefficients,smoothed)
            try context.dispatch("toneTransmission",width: size.width,height: size.height,
                textures: [moments,smoothed,transmission],value: &unused)
        } else {
            let ones = [SIMD4<Float>](repeating: SIMD4(1,0,0,0),count: size.width*size.height)
            ones.withUnsafeBytes { transmission.replace(region: MTLRegionMake2D(0,0,size.width,size.height),
                mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: size.width*16) }
        }
        let output: any MTLTexture
        if keyTone.clarity != 0 {
            p.toneAtmosphere = air
            try context.dispatch("toneLogMoments",width: size.width,height: size.height,
                textures: [exposed,exposedBase,transmission,moments],value: &p)
            try box(moments,means)
            try context.dispatch("toneLogCoefficients",width: size.width,height: size.height,
                textures: [means,coefficients],value: &unused)
            try box(coefficients,smoothed)
            output = try texture()
            try context.dispatch("toneFinishMap",width: size.width,height: size.height,
                textures: [moments,smoothed,transmission,output],value: &unused)
        } else { output = transmission }
        try finish(finishMap)
        try Task.checkCancellation()
        // Pack the fixed guide beside the graph's LUT/curve table. Every native
        // region reads the same grid without extra per-region textures or halos.
        let rgba = Self.readTexture(output)
        let values = stride(from: 0,to: rgba.count,by: 4).map { SIMD4(rgba[$0],rgba[$0+1],rgba[$0+2],Float(0)) }
        let map = ToneSpatialMap(size: size,air: SIMD3(air.x,air.y,air.z),values: values)
        toneSpatialCache = (key,map)
        return map
    }
}
