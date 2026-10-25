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
    /// Match the camera display rendition with a full-strength LUT. The fixed
    /// scene and centre-weighted log median are shared with the film meter.
    public func lutMeter(_ source: RenderSource, lut: ColorLUT, input: LUTSpace, output: LUTSpace) throws -> Float {
        let fixed = try fixedAnalysisSource(source)
        let key = LUTMeterKey(source: fixed.id, hash: lut.contentHash, input: input, output: output)
        if let cached = lutMeterCache[key] { return cached }
        // Metering renders temporarily use the analysis/cache slots. Restore the
        // live analysis so dragging strength does not replace it with a trial.
        let savedAnalysis = analysisCache
        defer { analysisCache = savedAnalysis }
        func smallSource(_ original: RenderSource) throws -> RenderSource {
            let input = try workingInput(original)
            let image = CIImage(mtlTexture: input, options: [.colorSpace: Self.workingColorSpace])!
                .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(input.height)))
            let scale = min(1, 192 / Double(max(input.width, input.height)))
            let width = max(1, Int((Double(input.width) * scale).rounded()))
            let height = max(1, Int((Double(input.height) * scale).rounded()))
            let reduced = image.clampedToExtent().transformed(by: CGAffineTransform(
                scaleX: Double(width) / Double(input.width), y: Double(height) / Double(input.height)))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            return try self.source(image: reduced, domain: original.domain == .dual ? .hdr : original.domain)
        }
        func brightness(_ source: RenderSource, _ edit: RenderAdjustments, size: PixelSize? = nil) throws -> Double {
            let planes = try render(source, adjustments: edit, size: size)
            let input = planes.base
            guard let command = queue.makeCommandBuffer(),
                  let rows = device.makeBuffer(length: input.width * input.height * 8, options: .storageModeShared)
            else { throw RenderError.allocationFailed }
            var unused: UInt32 = 0
            try nodeContext(domain: source.domain, buffer: command).dispatch("filmMeter",
                width: input.height, height: 1, textures: [input], buffers: [rows], value: &unused)
            try finish(command)
            let sums = UnsafeBufferPointer(start: rows.contents().bindMemory(to: SIMD2<Float>.self,
                capacity: input.width * input.height), count: input.width * input.height)
            let sorted = sums.sorted { $0.x < $1.x }
            let halfway = sorted.reduce(0.0) { $0 + Double($1.y) } / 2
            var weight = 0.0
            for sample in sorted {
                weight += Double(sample.y)
                if weight >= halfway { return Double(sample.x) }
            }
            return Double(sorted.last!.x)
        }
        let scene: RenderSource, target: Double
        if let cached = filmMeterInputCache, cached.id == fixed.id {
            scene = cached.scene; target = cached.target
        } else {
            scene = try smallSource(fixed)
            target = try brightness(modelInputSource(source), RenderAdjustments(), size: scene.size)
            filmMeterInputCache = (fixed.id, scene, target)
        }
        var edit = RenderAdjustments()
        edit.look.lut = lut; edit.look.strength = 1; edit.look.input = input; edit.look.output = output
        edit.effects.grain = 0; edit.effects.halation = 0
        let range = Adjustments.declaration("look.exposure")!.range!
        var low = range.lowerBound, high = range.upperBound
        func residual(_ ev: Double) throws -> Double {
            edit.look.exposure = Float(ev)
            return try brightness(scene, edit) - target
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
