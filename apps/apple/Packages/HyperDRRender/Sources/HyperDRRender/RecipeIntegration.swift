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
        // Index is LUTSpace.rawValue. Append only; the shader and Kit use the same order.
        let names = ["srgb","p3","rec709","hlg","pq","slog3-sgamut3cine","slog3-sgamut3","vlog-vgamut","flog2-fgamut","logc3-awg3","logc4-awg4","clog3-cinemagamut"]
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
        tone.whites = try values.number("tone.whites")
        tone.blacks = try values.number("tone.blacks")
        guard case .array(let points) = values.value("tone.curve") else { throw RenderError.invalidAdjustment }
        let coordinates = points.compactMap(\.numberValue)
        guard coordinates.count == points.count else { throw RenderError.invalidAdjustment }
        do { tone.curve = try ToneCurve(coordinates) } catch { throw RenderError.invalidAdjustment }
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
        film.strength = try values.number("look.filmStrength")
        effects.grain = try values.number("effect.grain")
        film.exposure = try values.optionalNumber("look.filmExposure")
        effects.halation = try values.number("effect.halation")
        film.antihalation = try values.bool("look.filmAntihalation")
        guard let stock = values.value("look.film")?.stringValue, Adjustments.filmStocks.contains(stock) else { throw RenderError.invalidAdjustment }
        film.stock = FilmStockID(rawValue: stock)
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
        self.init(rawResolution:rawResolution, resolution:resolution,
                  sceneLinear:Self.sceneLinearDevelopment(recipe:recipe,options:options))
        rawDecoderVersion = recipe.rawDecoderVersion
        geometry = recipe.geometry
        let values = RecipeValues(recipe:recipe,options:options)
        lensCorrection = try values.bool("develop.lensCorrection")
        raw.temperature = try values.optionalNumber("develop.temperature")
        raw.tint = try values.optionalNumber("develop.tint")
        raw.luminanceNR = try values.optionalNumber("develop.luminanceNR")
        raw.colorNR = try values.optionalNumber("develop.colorNR")
        raw.sharpness = try values.optionalNumber("develop.sharpness")
    }

    /// A film, or a log look, that will actually be applied (a film is chosen with a
    /// nonzero colour strength or physical effects; or a LUT is enabled and its strength is
    /// not zero). Film exposes the scene, so it takes RAW without Apple's tone curve.
    /// A bypassed look group reads as the defaults, so the comparison original stays
    /// on Apple's curve.
    static func sceneLinearDevelopment(recipe: Recipe, options: RenderOptions) -> Bool {
        // Raster photos already carry their display rendition. Film must not
        // treat that input as a RAW development or reopen it through CIRAWFilter.
        guard recipe.inputDomain == .rawEDR else { return false }
        let values = RecipeValues(recipe:recipe,options:options)
        if let film = values.value("look.film")?.stringValue, film != Adjustments.filmStocks[0],
           let strength = try? values.number("look.filmStrength"),
           strength > 0 || Adjustments.effectIDs.contains(where: { ((try? values.number($0)) ?? 0) > 0 }) { return true }
        guard recipe.look != nil else { return false }
        guard (try? values.bool("look.enabled")) == true,
              let strength = try? values.number("look.strength"), strength != 0,
              let space = try? values.space("look.input"), space.isLog else { return false }
        return true
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
