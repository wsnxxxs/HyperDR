import Foundation
import CoreImage
import Metal
import HyperDRRecipe

struct LUTMeterKey: Hashable {
    let source: UUID
    let hash: String
    let input, output: LUTSpace
}

extension RenderEngine {
    /// Match the camera's rendition (`meterTarget`) with a full-strength LUT. The fixed
    /// scene and centre-weighted log median are shared with the film meter.
    public func lutMeter(_ source: RenderSource, lut: ColorLUT, input: LUTSpace, output: LUTSpace) throws -> Float {
        let fixed = try fixedAnalysisSource(source)
        let key = LUTMeterKey(source: fixed.id, hash: lut.contentHash, input: input, output: output)
        if let cached = lutMeterCache[key] { return cached }
        // Metering renders temporarily use the analysis/cache slots. Restore the
        // live analysis so dragging strength does not replace it with a trial.
        let savedAnalysis = analysisCache
        defer { analysisCache = savedAnalysis }
        let scene: RenderSource, target: Double
        if let cached = filmMeterInputCache, cached.id == fixed.id {
            scene = cached.scene; target = cached.target
        } else {
            scene = try smallMeterSource(fixed)
            target = try meterTarget(source) { try meterBrightness(modelInputSource(source), RenderAdjustments(), size: scene.size) }
            filmMeterInputCache = (fixed.id, scene, target)
        }
        var edit = RenderAdjustments()
        edit.look.lut = lut; edit.look.strength = 1; edit.look.input = input; edit.look.output = output
        edit.effects.grain = 0; edit.effects.halation = 0
        let range = Adjustments.declaration("look.exposure")!.range!
        var low = range.lowerBound, high = range.upperBound
        func residual(_ ev: Double) throws -> Double {
            edit.look.exposure = Float(ev)
            return try meterBrightness(scene, edit) - target
        }
        var a = try residual(low), b = try residual(high)
        var ev = abs(a) < abs(b) ? low : high
        if a < 0 && b > 0 {
            for _ in 0..<9 {
                // Bracketed secant: avoid stalling on the film's flat shoulders.
                ev = min(high - 0.1 * (high-low), max(low + 0.1 * (high-low), low - a * (high-low) / (b-a)))
                let value = try residual(ev)
                if abs(value) < 0.005 { break }
                if value < 0 { low = ev; a = value } else { high = ev; b = value }
            }
        }
        lutMeterCache[key] = Float(ev)
        return Float(ev)
    }

}
