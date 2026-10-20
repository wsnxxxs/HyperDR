import Foundation
import HyperDRRecipe

/// Catalogue access shared by validation, defaults and the recipe boundary.
/// Numeric unit conversion belongs exclusively to ParameterDeclaration.engineValue.
enum RenderParameter {
    static func declaration(_ id: String) -> ParameterDeclaration { Adjustments.declaration(id)! }
    static func defaultNumber(_ id: String) -> Float {
        let parameter = declaration(id)
        guard case .constant(.number(let value)) = parameter.defaultValue(in:.sdr) else {
            preconditionFailure("Expected numeric constant: \(id)")
        }
        return Float(parameter.engineValue(value))
    }
    static func defaultBool(_ id: String) -> Bool {
        guard case .constant(.bool(let value)) = declaration(id).defaultValue(in:.sdr) else {
            preconditionFailure("Expected boolean constant: \(id)")
        }
        return value
    }
    static var expansionStart: Float {
        Float(declaration("hdr.expansionStart").engineValue(Adjustments.automaticExpansionStart))
    }
    static func check(_ value: Float, id: String) throws {
        let parameter = declaration(id), range = parameter.range!
        let engineRange = Float(parameter.engineValue(range.lowerBound))...Float(parameter.engineValue(range.upperBound))
        guard value.isFinite, engineRange.contains(value) else { throw RenderError.invalidAdjustment }
    }
}

private struct RecipeValues {
    let recipe: Recipe
    var options = RenderOptions()
    func value(_ id: String) -> ParameterValue? {
        let parameter = RenderParameter.declaration(id)
        if !options.bypassedGroups.contains(parameter.group), parameter.allows(recipe.inputDomain),
           let value = recipe.value(for:id) { return value }
        guard case .constant(let value) = parameter.defaultValue(in:recipe.inputDomain) else { return nil }
        return value
    }
    func optionalNumber(_ id: String) throws -> Float? {
        guard let stored = value(id) else { return nil }
        let parameter = RenderParameter.declaration(id)
        guard let number = stored.numberValue, number.isFinite,
              parameter.range!.contains(number) else { throw RenderError.invalidAdjustment }
        return Float(parameter.engineValue(number))
    }
    func number(_ id: String) throws -> Float {
        guard let value = try optionalNumber(id) else { throw RenderError.invalidAdjustment }
        return value
    }
    func bool(_ id: String) throws -> Bool {
        guard let result = value(id)?.boolValue else { throw RenderError.invalidAdjustment }
        return result
    }
    func space(_ id: String) throws -> LUTSpace {
        let names = ["srgb","p3","rec709","hlg","pq","slog3-sgamut3cine"]
        guard let name = value(id)?.stringValue, let index = names.firstIndex(of:name),
              let result = LUTSpace(rawValue:UInt32(index)) else { throw RenderError.invalidAdjustment }
        return result
    }
}

extension RenderAdjustments {
    /// Resolve declared recipe units once. The caller resolves recipe.look by its
    /// content hash; an active LUT must match that reference. Bookmarks stay outside Render.
    public init(recipe: Recipe, lut: ColorLUT? = nil, options: RenderOptions = RenderOptions()) throws {
        self.init()
        let values = RecipeValues(recipe:recipe,options:options)
        tone.exposure = try values.number("tone.exposure")
        tone.contrast = try values.number("tone.contrast")
        tone.highlights = try values.number("tone.highlights")
        tone.shadows = try values.number("tone.shadows")
        tone.blacks = try values.number("tone.blacks")
        color.warmth = try values.number("color.warmth")
        color.tint = try values.number("color.tint")
        color.vibrance = try values.number("color.vibrance")
        color.saturation = try values.number("color.saturation")
        hdr.enabled = try values.bool("hdr.enabled")
        if options.bypassedGroups.contains(.hdr) { hdr.enabled = false }
        hdr.source = options.bypassedGroups.contains(.hdr) ? nil : recipe.hdrSource
        hdr.strength = try values.number("hdr.strength")
        hdr.range = try values.optionalNumber("hdr.range")
        hdr.expansionStart = try values.optionalNumber("hdr.expansionStart")
        hdr.coverage = try values.number("hdr.coverage")
        hdr.sdrRolloff = try values.number("hdr.sdrRolloff")
        look.enabled = try values.bool("look.enabled")
        look.strength = try values.number("look.strength")
        look.input = try values.space("look.input")
        look.output = try values.space("look.output")
        if !options.bypassedGroups.contains(.look), let reference = recipe.look {
            if let lut, lut.contentHash != reference.contentHash { throw RenderError.invalidLUT("LUT content hash mismatch") }
            if look.enabled && look.strength != 0 && lut == nil { throw RenderError.invalidLUT("Resolve recipe.look before rendering") }
            look.lut = lut
        }
        try validate(domain:recipe.inputDomain)
    }
}

extension SourceOptions {
    public init(recipe: Recipe, rawResolution: RAWResolution? = nil, resolution: SourceResolution = .full, options: RenderOptions = RenderOptions()) throws {
        self.init(rawResolution:rawResolution, resolution:resolution)
        let values = RecipeValues(recipe:recipe,options:options)
        lensCorrection = try values.bool("develop.lensCorrection")
        raw.temperature = try values.optionalNumber("develop.temperature")
        raw.tint = try values.optionalNumber("develop.tint")
        raw.luminanceNR = try values.optionalNumber("develop.luminanceNR")
        raw.colorNR = try values.optionalNumber("develop.colorNR")
        raw.sharpness = try values.optionalNumber("develop.sharpness")
    }
}

extension RenderEngine {
    public func render(_ source: RenderSource, recipe: Recipe, lut: ColorLUT? = nil,
                       modelGain: ModelGainPrediction? = nil, options: RenderOptions = RenderOptions(),
                       size: PixelSize? = nil, region: CGRect? = nil) throws -> RenderPlanes {
        guard recipe.inputDomain == source.domain else { throw RenderError.invalidAdjustment }
        var edit = try RenderAdjustments(recipe:recipe,lut:lut,options:options)
        edit.hdr.modelGain = modelGain
        return try render(source,adjustments:edit,size:size,region:region)
    }
    public func renderStripes(_ source: RenderSource, recipe: Recipe, lut: ColorLUT? = nil,
                              modelGain: ModelGainPrediction? = nil, options: RenderOptions = RenderOptions(),
                              size: PixelSize? = nil, rows: Int = 256,
                              consume: @Sendable (RenderPlanes) throws -> Void) throws {
        guard recipe.inputDomain == source.domain else { throw RenderError.invalidAdjustment }
        var edit = try RenderAdjustments(recipe:recipe,lut:lut,options:options)
        edit.hdr.modelGain = modelGain
        try renderStripes(source,adjustments:edit,size:size,rows:rows,consume:consume)
    }
}
