import Foundation

/// Render-side values while the complete Recipe schema is being developed.
/// Signed controls use the design's -100...100 scale; strengths use 0...1.
public struct ToneAdjustments: Hashable, Sendable {
    public var exposure: Float = 0
    public var contrast: Float = 0
    public var highlights: Float = 0
    public var shadows: Float = 0
    public var blacks: Float = 0
    public init() {}
    public var isIdentity: Bool { self == Self() }
}

public struct ColorAdjustments: Hashable, Sendable {
    public var warmth: Float = 0
    public var tint: Float = 0
    public var vibrance: Float = 0
    public var saturation: Float = 0
    public init() {}
    public var isIdentity: Bool { self == Self() }
}

/// Nil means CIRAWFilter's file/camera default, not zero. Source cache identity
/// includes all development values. Values for NR/sharpness are normalized 0...1.
public struct RAWAdjustments: Hashable, Sendable {
    public var temperature: Float?
    public var tint: Float?
    public var luminanceNR: Float?
    public var colorNR: Float?
    public var sharpness: Float?
    public init() {}
}

public enum HDRSource: String, Hashable, Sendable {
    case automatic, expand, captured, capturedExpand, ai, capturedAI
}

public struct HDRAdjustments: Hashable, Sendable {
    public var enabled = true
    public var source: HDRSource = .automatic
    public var strength: Float = 1
    public var range: Float? = nil
    public var expansionStart: Float? = nil
    public var coverage: Float = 0.6
    public var sdrRolloff: Float = 0
    public init() {}
    public var isIdentity: Bool { self == Self() }
}

public struct LookAdjustments: Hashable, Sendable {
    public var lut: ColorLUT?
    public var enabled = true
    public var strength: Float = 1
    public var input: LUTSpace = .sRGB
    public var output: LUTSpace = .sRGB
    public init() {}
    public var isIdentity: Bool { !enabled || lut == nil || strength == 0 }
}

public struct RenderAdjustments: Hashable, Sendable {
    public var tone = ToneAdjustments()
    public var color = ColorAdjustments()
    public var look = LookAdjustments()
    public var hdr = HDRAdjustments()
    public init() {}
    public var wholeImageIsIdentity: Bool { tone.isIdentity && color.isIdentity && look.isIdentity }

    func validate() throws {
        func check(_ value: Float, _ range: ClosedRange<Float>) throws {
            guard value.isFinite && range.contains(value) else { throw RenderError.invalidAdjustment }
        }
        try check(tone.exposure, -4...4)
        for value in [tone.contrast, tone.highlights, tone.shadows, tone.blacks,
                      color.warmth, color.tint, color.vibrance, color.saturation] { try check(value, -100...100) }
        try check(hdr.strength, 0...2)
        try check(hdr.coverage, 0...1)
        try check(hdr.sdrRolloff, 0...1)
        if let range = hdr.range { try check(range, 0.5...4) }
        if let start = hdr.expansionStart { try check(start, 0.18...0.75) }
        try check(look.strength, 0...1)
        if !look.isIdentity {
            guard !(look.input.isSDR && !look.output.isSDR),
                  look.output != .sLog3 || look.input == .sLog3 else { throw RenderError.invalidAdjustment }
        }
        if hdr.source == .ai || hdr.source == .capturedAI { throw RenderError.aiNotAvailable }
    }
}

/// Metadata IDs join to HyperDRRecipe's declaration catalogue. No duplicate
/// ranges/default declarations are owned by Render's adjustment nodes.
public enum AdjustmentIDs {
    public static let tone = ["tone.exposure", "tone.contrast", "tone.highlights", "tone.shadows", "tone.blacks"]
    public static let color = ["color.warmth", "color.tint", "color.vibrance", "color.saturation"]
    public static let raw = ["develop.temperature", "develop.tint", "develop.luminanceNR", "develop.colorNR", "develop.sharpness", "develop.lensCorrection"]
    public static let hdr = ["hdr.enabled", "hdr.source", "hdr.strength", "hdr.range", "hdr.expansionStart", "hdr.coverage", "hdr.sdrRolloff"]
    public static let look = ["look.lut", "look.enabled", "look.strength", "look.input", "look.output"]
}
