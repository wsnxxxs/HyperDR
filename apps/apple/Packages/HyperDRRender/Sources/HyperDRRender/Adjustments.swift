import Foundation
import HyperDRRecipe

/// Resolved engine values. Use RenderAdjustments(recipe:lut:) for declared recipe units.
/// Signed controls are -1...1; contrast is a multiplier (default 1).
public struct ToneAdjustments: Hashable, Sendable {
    public var exposure: Float = RenderParameter.defaultNumber("tone.exposure")
    public var contrast: Float = RenderParameter.defaultNumber("tone.contrast")
    public var highlights: Float = RenderParameter.defaultNumber("tone.highlights")
    public var shadows: Float = RenderParameter.defaultNumber("tone.shadows")
    public var whites: Float = RenderParameter.defaultNumber("tone.whites")
    public var blacks: Float = RenderParameter.defaultNumber("tone.blacks")
    public init() {}
    public var isIdentity: Bool { self == Self() }
}

public struct ColorAdjustments: Hashable, Sendable {
    public var warmth: Float = RenderParameter.defaultNumber("color.warmth")
    public var tint: Float = RenderParameter.defaultNumber("color.tint")
    public var vibrance: Float = RenderParameter.defaultNumber("color.vibrance")
    public var saturation: Float = RenderParameter.defaultNumber("color.saturation")
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

public struct HDRAdjustments: Hashable, Sendable {
    public var modelGain: ModelGainPrediction?
    public var enabled = RenderParameter.defaultBool("hdr.enabled")
    /// Nil resolves to HyperDRRecipe.HDRSource.defaultSource(for:) at rendering.
    public var source: HyperDRRecipe.HDRSource? = nil
    public var strength: Float = RenderParameter.defaultNumber("hdr.strength")
    public var range: Float? = nil
    public var expansionStart: Float? = nil
    public var coverage: Float = RenderParameter.defaultNumber("hdr.coverage")
    public var sdrRolloff: Float = RenderParameter.defaultNumber("hdr.sdrRolloff")
    public init() {}
    public var isIdentity: Bool { var value = self; value.source = nil; value.modelGain = nil; return value == Self() }
}

public struct LookAdjustments: Hashable, Sendable {
    public var lut: ColorLUT?
    public var enabled = RenderParameter.defaultBool("look.enabled")
    public var strength: Float = RenderParameter.defaultNumber("look.strength")
    public var input: LUTSpace = .sRGB
    public var output: LUTSpace = .sRGB
    public init() {}
    public var isIdentity: Bool { !enabled || lut == nil || strength == 0 }
}

/// Independent physical effects. One is a typical 35 mm frame, zero bypasses it.
public struct EffectAdjustments: Hashable, Sendable {
    public var grain: Float = RenderParameter.defaultNumber("effect.grain")
    public var halation: Float = RenderParameter.defaultNumber("effect.halation")
    public init() {}
    public var isIdentity: Bool { grain == 0 && halation == 0 }
}

public struct RenderAdjustments: Hashable, Sendable {
    public var tone = ToneAdjustments()
    public var color = ColorAdjustments()
    public var look = LookAdjustments()
    public var film = FilmAdjustments()
    public var effects = EffectAdjustments()
    public var hdr = HDRAdjustments()
    public init() {}
    public var wholeImageIsIdentity: Bool { tone.isIdentity && color.isIdentity && look.isIdentity && film.isIdentity && effects.isIdentity }

    /// Stock physics stays active even when its colour crossfade is zero.
    var usesFilmProcessing: Bool { film.stock != nil && (film.strength > 0 || !effects.isIdentity) }

    public func sourceHalo(size: PixelSize) -> Int {
        usesFilmProcessing ? film.sourceHalo(size: size) : 0
    }

    func validate(domain: InputDomain) throws {
        for (id,value) in [("tone.exposure",tone.exposure),("tone.contrast",tone.contrast),
            ("tone.highlights",tone.highlights),("tone.shadows",tone.shadows),("tone.whites",tone.whites),("tone.blacks",tone.blacks),
            ("color.warmth",color.warmth),("color.tint",color.tint),("color.vibrance",color.vibrance),
            ("color.saturation",color.saturation),("hdr.strength",hdr.strength),("hdr.coverage",hdr.coverage),
            ("hdr.sdrRolloff",hdr.sdrRolloff),("look.strength",look.strength),("look.filmStrength",film.strength),("effect.grain",effects.grain),("effect.halation",effects.halation)] {
            try RenderParameter.check(value,id:id)
        }
        if let range = hdr.range { try RenderParameter.check(range,id:"hdr.range") }
        if let exposure = film.exposure { try RenderParameter.check(exposure,id:"look.filmExposure") }
        if let start = hdr.expansionStart { try RenderParameter.check(start,id:"hdr.expansionStart") }
        guard look.isIdentity || !usesFilmProcessing else { throw RenderError.invalidAdjustment }
        if !look.isIdentity {
            guard !look.input.isLog || domain == .rawEDR else { throw RenderError.invalidAdjustment }
        }
        let source = hdr.source ?? .defaultSource(for:domain)
        guard source.domains.contains(domain) else { throw RenderError.invalidAdjustment }
        if domain == .rawEDR && (color.warmth != 0 || color.tint != 0) { throw RenderError.invalidAdjustment }
    }
}
