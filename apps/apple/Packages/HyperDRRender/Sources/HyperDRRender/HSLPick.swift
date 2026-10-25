import Foundation
import HyperDRRecipe
import Metal

public struct HSLColorSample: Sendable {
    /// Eight memberships in HSLBand order. Neutrals fade to zero; chromatic
    /// samples sum to one. These are weights at the input of the mixer.
    public let weights: [Double]
    public init(weights: [Double]) { self.weights = weights }
}

extension RenderEngine {
    /// Normalized, top-left coordinates on the geometry-applied source, just
    /// as the white-balance picker. Sample before HSL, grading and the look.
    public func pickHSL(_ source: RenderSource, recipe: Recipe, at point: CGPoint,
                        lut: ColorLUT? = nil, options: RenderOptions = RenderOptions()) throws -> HSLColorSample {
        let edit = try RenderAdjustments(recipe: recipe,lut: lut,options: options)
        let input = try workingInput(source)
        let resources = try lookupResources(lut,curve: edit.tone.curve)
        guard let command = queue.makeCommandBuffer(),
              let result = device.makeBuffer(length: 16,options:.storageModeShared) else { throw RenderError.allocationFailed }
        var uniform = graphUniform(source,edit,size:source.size,
            region:CGRect(x:0,y:0,width:source.size.width,height:source.size.height))
        uniform.region.z = UInt32(min(input.width-1,max(0,Int(point.x*Double(input.width)))))
        uniform.region.w = UInt32(min(input.height-1,max(0,Int(point.y*Double(input.height)))))
        try nodeContext(domain:source.domain,buffer:command).dispatch("graphMixerSample",width:1,height:1,
            textures:[input,resources.texture],buffers:[resources.buffer,result],value:&uniform)
        try finish(command)
        let pixel = result.contents().load(as:SIMD4<Float>.self)
        return HSLColorSample(weights:DoubleReference.hslWeights(SIMD3(Double(pixel.x),Double(pixel.y),Double(pixel.z))))
    }
}
