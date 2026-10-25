import Foundation
import Metal
import simd

private struct ClippingUniform {
    var p3ToGain, gainToP3: simd_float3x3
    var baseOffset, alternateOffset: SIMD4<Float>
    var controls: SIMD4<Float>
}

extension RenderEngine {
    /// RG32Float: red = dead black (all SDR channels <= 1/1023), green =
    /// clipping. HDR clipping starts at the range shoulder knee; SDR at white.
    /// This is a display overlay only. It never changes preview/export pixels.
    public func clippingMask(_ pair: DisplayGainPair, range: Float, hdrEnabled: Bool) throws -> RenderMask {
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let node = nodeContext(domain: .hdr, buffer: command)
        let output = try node.texture(width: pair.base.width, height: pair.base.height, format: .rg32Float)
        var p = ClippingUniform(p3ToGain: pair.p3ToGain, gainToP3: pair.gainToP3,
            baseOffset: SIMD4(pair.baseOffset, 0), alternateOffset: SIMD4(pair.alternateOffset, 0),
            controls: SIMD4(Float(pair.gainChannelCount), exp2(range), hdrEnabled ? 1 : 0, 0))
        try node.dispatch("clippingMask", width: output.width, height: output.height,
                          textures: [pair.base, pair.gain, output], value: &p)
        try finish(command)
        return RenderMask(texture: output, region: pair.region, outputSize: pair.outputSize)
    }
}
