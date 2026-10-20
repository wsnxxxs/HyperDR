import CoreGraphics
import Metal
import os
import simd

/// What the canvas shows for one rendition: a linear Display P3 base and the
/// decoded log2 gain that takes it to the alternate rendition (ISO 21496-1,
/// gpu-pipeline §11), applied in the gain's working space. Render produces it
/// and resolves min/max/gamma and ICC; the display layer alone decides how
/// much of the gain the screen gets. Export never passes through here.
///
/// Both textures are top-down and must not be written once the pair exists:
/// the compositor caches by texture identity. The gain may be smaller than
/// the base; it is resampled bilinearly in its stored coding, then decoded.
nonisolated struct DisplayPair: @unchecked Sendable {
    enum GainCoding: Equatable, Sendable {
        /// The texel is log2 of the gain, in stops.
        case log2
        /// The "gain" is the alternate rendition itself, at the base's size:
        /// the engine's v1 frames (details, LUT and SDR-clamped previews)
        /// until the Mac editor renders through HyperDRRender. Weight 0 is
        /// the base and 1 the alternate, exactly.
        case alternate
    }

    /// Linear extended Display P3 (`rgba16Float` or `rgba32Float`).
    let base: any MTLTexture
    /// One channel (an R format) or three (the RGB of an RGBA format).
    let gain: any MTLTexture
    var coding: GainCoding = .log2
    var baseOffset = SIMD3<Float>(repeating: 0)
    var alternateOffset = SIMD3<Float>(repeating: 0)
    /// Display P3 → the gain's working space, and back.
    var toGain = matrix_identity_float3x3
    var toP3 = matrix_identity_float3x3
    /// log2 headroom of the base and of the alternate rendition.
    var baseHeadroom: Double = 0
    var alternateHeadroom: Double
    /// A detail layer: where its pixels sit in the whole image, in source pixels.
    var region: CGRect?

    var width: Int { base.width }
    var height: Int { base.height }
    var gainChannels: Int {
        switch gain.pixelFormat {
        case .r8Unorm, .r16Unorm, .r16Float, .r32Float: 1
        default: 3
        }
    }

    /// Same textures and the same decoding.
    func hasSameContent(as other: DisplayPair) -> Bool {
        base === other.base && gain === other.gain && coding == other.coding
            && baseOffset == other.baseOffset && alternateOffset == other.alternateOffset
            && toGain == other.toGain && toP3 == other.toP3 && region == other.region
    }

    /// The share of the gain a screen with `headroom` (linear) shows.
    func weight(headroom: Double) -> Float {
        DisplayWeight.value(headroom: headroom, base: baseHeadroom, alternate: alternateHeadroom)
    }
}

/// ISO 21496-1 weight: where the screen's headroom falls between the base's
/// and the alternate's, clamped to 0…1.
nonisolated enum DisplayWeight {
    static let rebuildThreshold: Float = 0.005
    static func value(headroom: Double, base: Double, alternate: Double) -> Float {
        let denominator = alternate - base
        guard headroom.isFinite, headroom > 1, base.isFinite, alternate.isFinite,
              abs(denominator) >= 1e-8 else { return 0 }
        return Float(min(1, max(0, (log2(headroom) - base) / denominator)))
    }
    /// Compare with the last *rendered* weight, so small steps accumulate.
    /// Endpoints are exact: never leave a residual HDR contribution on SDR.
    static func needsRebuild(from old: Float?, to new: Float) -> Bool {
        guard let old else { return true }
        return abs(new - old) > rebuildThreshold || (new != old && (new == 0 || new == 1))
    }
}

/// Timing for one publication, so the shared canvas needs no engine types.
/// The Mac target's `PreviewTrace` conforms; iOS passes none.
nonisolated protocol CanvasTrace: AnyObject, Sendable {
    func begin(_ stage: StaticString) -> OSSignpostIntervalState
    func end(_ stage: StaticString, _ interval: OSSignpostIntervalState)
    /// The compute encoder for one layer's rebuild (GPU timing samples, if any).
    func makeLayerEncoder(device: any MTLDevice, command: any MTLCommandBuffer) -> (any MTLComputeCommandEncoder)?
}
