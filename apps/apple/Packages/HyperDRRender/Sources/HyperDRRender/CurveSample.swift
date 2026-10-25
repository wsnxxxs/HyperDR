import Foundation
import simd
import HyperDRRecipe

public struct CurveSample: Sendable {
    /// sRGB lightness at/below white; 1 + stops above white in the HDR segment.
    public let coordinate: Double
}

extension RenderEngine {
    /// Normalized top-left coordinates of the geometry-applied photo.
    public func pickCurve(_ source: RenderSource, recipe: Recipe, parameterID: String, point: CGPoint,
                          lut: ColorLUT? = nil, modelGain: ModelGainPrediction? = nil,
                          options: RenderOptions = RenderOptions(), size: PixelSize? = nil) throws -> CurveSample {
        let size = size ?? source.size
        let x = min(size.width-1,max(0,Int(point.x*Double(size.width))))
        let y = min(size.height-1,max(0,Int(point.y*Double(size.height))))
        let region = CGRect(x: x,y: y,width: 1,height: 1)
        var edit = try RenderAdjustments(recipe: recipe,lut: lut,options: options)
        edit.hdr.modelGain = modelGain
        let channel = ["tone.curveRed","tone.curveGreen","tone.curveBlue"].firstIndex(of: parameterID)
        guard channel != nil || ["tone.curve","tone.curveSDR","tone.curveHDR"].contains(parameterID) else {
            throw RenderError.invalidAdjustment
        }
        func endpointInput(_ stage: UInt32) throws -> CurveSample {
            var probe = edit
            probe.tone.curveProbeStage = stage
            let planes = try render(source,adjustments: probe,size: size,region: region)
            let pixel = Self.readTexture(planes.base)
            return CurveSample(coordinate: DoubleReference.curveCoordinate(DoubleReference.luma(
                .init(Double(pixel[0]),Double(pixel[1]),Double(pixel[2])))))
        }
        if parameterID == "tone.curveSDR" { return try endpointInput(3) }
        if parameterID == "tone.curveHDR" { return try endpointInput(4) }
        let resources = try lookupResources(edit.look.isIdentity ? nil : edit.look.lut,tone: edit.tone)
        let input = try workingInput(source)
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let context = nodeContext(domain: source.domain,buffer: command)
        let output = try context.texture(width: 1,height: 1)
        var p = graphUniform(source,edit,size: size,region: region)
        p.light.w = channel == nil ? 1 : 2
        try context.dispatch("curveProbe",width: 1,height: 1,textures: [input,output,resources.texture],
                             buffers: [resources.buffer],value: &p)
        try finish(command)
        let pixel = Self.readTexture(output)
        let value = channel.map { Double(pixel[$0]) }
            ?? DoubleReference.luma(.init(Double(pixel[0]),Double(pixel[1]),Double(pixel[2])))
        if channel == nil {
            let final = try endpointInput(5)
            if final.coordinate > 1 { return final }
        }
        let coordinate = DoubleReference.curveCoordinate(value)
        return CurveSample(coordinate: channel == nil && coordinate <= 1 ? edit.tone.parametricValue(at: coordinate) : coordinate)
    }
}
