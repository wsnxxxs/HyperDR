import Foundation
import Testing
@testable import HyperDRRecipe

@Test func parameterTableIsComplete() throws {
    let all = Adjustments.all
    #expect(all.count == 48)
    #expect(Set(all.map(\.id)).count == all.count, "duplicate parameter ids")
    #expect(Adjustments.byID.count == all.count)

    // 6 RAW-only parameters; the local group is reserved and declares nothing yet.
    #expect(all.filter { $0.domains == [.rawEDR] }.count == 6)
    #expect(Adjustments.parameters(in: .local).isEmpty)
    for group in ParameterGroup.displayOrder where group != .local {
        #expect(!Adjustments.parameters(in: group).isEmpty, "empty group \(group.rawValue)")
    }

    for declaration in all {
        if declaration.kind == .choice {
            #expect(!declaration.options.isEmpty, "\(declaration.id) has no options")
            let defaultID = try #require(declaration.defaultValue(in: .sdr).constantString)
            #expect(declaration.option(defaultID) != nil, "\(declaration.id) default is not an option")
            for option in declaration.options {
                #expect(declaration.domains.isSuperset(of: option.domains), "\(option.labelKey)")
            }
        } else {
            #expect(declaration.options.isEmpty, "\(declaration.id) declares options")
        }

        switch declaration.defaultValue(in: .rawEDR) {
        case .constant(.number(let value)):
            let range = try #require(declaration.range, "\(declaration.id) has no range")
            #expect(range.contains(value), "\(declaration.id) default \(value) outside \(range)")
        case .constant:
            #expect(declaration.range == nil, "\(declaration.id) is numeric but not ranged")
        case .fromSource, .auto:
            #expect(declaration.range != nil, "\(declaration.id) resolves a number but has no range")
        case .byDomain:
            Issue.record("\(declaration.id) still has a per-domain default")
        }

        if declaration.range != nil {
            #expect(declaration.step != nil, "\(declaration.id) has no step")
            #expect(declaration.format != nil, "\(declaration.id) has no readout format")
        }
        #expect(declaration.labelKey == "ctrl.\(declaration.id).label")
        #expect(declaration.undoKey == "undo.\(declaration.id)")

        let encoded = try JSONEncoder().encode(declaration)
        #expect(try JSONDecoder().decode(ParameterDeclaration.self, from: encoded) == declaration,
                "\(declaration.id) does not survive a declaration round trip")
    }

    // hdr.source offers exactly the options its domain allows (p7-adjustments §2.3).
    let source = try #require(Adjustments.declaration("hdr.source"))
    #expect(HDRSource.options(in: .sdr).map(\.rawValue) == ["expand", "ai"])
    #expect(HDRSource.options(in: .rawEDR).map(\.rawValue) == ["captured", "capturedExpand", "capturedAI"])
    #expect(HDRSource.options(in: .dual).map(\.rawValue) == ["builtIn"])
    for option in source.options {
        #expect(option.labelKey == "hdr.source.\(option.id)")
    }
}

@Test func recipeRoundTripIsStable() throws {
    #expect(Recipe().version == Recipe.currentVersion)

    var recipe = Recipe(inputDomain: .rawEDR)
    #expect(recipe.hdrSource == .captured)
    recipe.setValue(.number(0.3), for: "tone.exposure")
    recipe.setValue(.number(70), for: "hdr.strength")
    recipe.setValue(.bool(false), for: "hdr.enabled")
    recipe.setValue(.number(-12), for: "tone.contrast")
    recipe.look = LUTReference(contentHash: "sha256:abc", name: "Kodak 2383", bookmark: Data([1, 2, 3]))
    let applied = recipe.setHDRSource(.capturedExpand)
    #expect(applied)
    let rejected = recipe.setHDRSource(.expand)
    #expect(!rejected, "expand does not apply to RAW")

    // Defaults are not stored.
    recipe.setValue(.number(60), for: "hdr.coverage")
    recipe.setValue(.number(0), for: "tone.blacks")
    #expect(recipe.value(for: "hdr.coverage") == nil)
    #expect(recipe.value(for: "tone.blacks") == nil)
    #expect(recipe.isDefault("hdr.coverage"))

    let data = try recipe.encoded()
    let restored = try Recipe.decode(data)
    #expect(restored == recipe)
    #expect(try restored.encoded() == data, "serialization is not stable")

    let json = try recipe.jsonString()
    #expect(!json.contains("hdr.coverage"))
    #expect(json.contains("\"hdrSource\":\"capturedExpand\""))
    // Sorted keys: hdrSource, inputDomain, look, values, version.
    let order = ["\"hdrSource\"", "\"inputDomain\"", "\"look\"", "\"values\"", "\"version\""]
    let positions = try order.map { try #require(json.range(of: $0)).lowerBound }
    #expect(positions == positions.sorted())

    // PHAdjustmentData envelope, without importing Photos.
    let adjustment = try recipe.adjustmentData()
    #expect(adjustment.formatIdentifier == "com.hyperdr.HyperDR.recipe")
    #expect(adjustment.formatVersion == "1")
    #expect(Recipe(adjustmentData: adjustment) == recipe)
    #expect(Recipe(adjustmentData: AdjustmentData(formatIdentifier: "com.other.app", data: data)) == nil)
}

@Test func unknownIDsSurviveARoundTrip() throws {
    let json = """
    {"version":2,"inputDomain":"hdr","hdrSource":"builtIn",
     "values":{"future.shadowDodge":-0.25,"future.mask":true,"future.name":"sky","tone.exposure":1.5}}
    """
    let recipe = try Recipe.decode(Data(json.utf8))
    #expect(recipe.version == 2)
    #expect(recipe.inputDomain == .hdr)
    #expect(recipe.value(for: "future.shadowDodge") == .number(-0.25))
    #expect(recipe.value(for: "future.mask") == .bool(true))
    #expect(recipe.value(for: "future.name") == .string("sky"))
    #expect(recipe.value(for: "tone.exposure") == .number(1.5))
    // Unknown ids are never treated as defaults, and are written back unchanged.
    #expect(!recipe.isDefault("future.shadowDodge"))
    let restored = try Recipe.decode(try recipe.encoded())
    #expect(restored == recipe)
    #expect(restored.value(for: "future.mask") == .bool(true))
}

@Test func restoringALogLookToANonRAWPhotoRemovesTheIncompatibleLook() throws {
    let look = LUTReference(contentHash: "sha256:" + String(repeating: "ab", count: 32), name: "Log")
    let inputs = try #require(Adjustments.declaration("look.input")).options.filter { $0.domains == [.rawEDR] }
    for input in inputs {
        let original = Recipe(inputDomain: .rawEDR, look: look, values: [
            "look.input": .string(input.id), "look.output": .string("rec709"), "tone.exposure": .number(1)])
        var raw = original
        raw.setInputDomain(.rawEDR)
        #expect(raw == original)
        for domain in [InputDomain.sdr, .hdr, .dual] {
            var restored = try Recipe.decode(original.encoded())
            restored.setInputDomain(domain)
            #expect(restored.conditionValue("look.input") == .string(input.id))
            #expect(restored.look == nil && restored.conditionValue("look.output") == .string("rec709"))
            #expect(restored.conditionValue("tone.exposure") == .number(1))
        }
    }
}

@Test func domainsAndConditionsFilterVisibleParameters() throws {
    let ids = { (domain: InputDomain) in Adjustments.visible(in: domain).map(\.id) }

    let sdr = ids(.sdr)
    #expect(sdr.contains("color.warmth") && sdr.contains("color.tint"))
    #expect(!sdr.contains("develop.temperature") && !sdr.contains("develop.sharpness"))
    #expect(!sdr.contains("hdr.sdrRolloff"), "SDR input has no separated base")

    let raw = ids(.rawEDR)
    #expect(raw.contains("develop.temperature") && raw.contains("develop.tint"))
    #expect(raw.contains("hdr.sdrRolloff"))
    #expect(!raw.contains("color.warmth"))

    #expect(ids(.hdr).contains("hdr.sdrRolloff"))
    #expect(!ids(.dual).contains("hdr.sdrRolloff"))
    for domain in InputDomain.allCases {
        #expect(ids(domain).contains("look.lut"))
    }

    // Conditions: the HDR group collapses with hdr.enabled, and the source picks
    // which of expansion start, coverage and model apply.
    var recipe = Recipe(inputDomain: .sdr)
    func visible() -> [String] { recipe.visibleParameters.map(\.id) }
    #expect(visible().contains("hdr.strength"))
    // The SDR default source is expansion: coverage shows, the model does not.
    #expect(recipe.hdrSource == .expand)
    #expect(visible().contains("hdr.coverage"))
    #expect(!visible().contains("hdr.model"))
    #expect(!visible().contains("look.strength"), "LUT controls need a chosen LUT")

    recipe.setValue(.string("ai"), for: "hdr.source")
    #expect(!visible().contains("hdr.coverage"), "AI has no coverage")
    #expect(visible().contains("hdr.model"))
    #expect(visible().contains("hdr.expansionStart"))

    recipe.setValue(.bool(false), for: "hdr.enabled")
    #expect(!visible().contains("hdr.strength"))
    #expect(!visible().contains("hdr.source"))

    recipe.setValue(nil, for: "hdr.enabled")
    recipe.look = LUTReference(contentHash: "sha256:abc", name: "Test")
    #expect(visible().contains("look.strength") && visible().contains("look.enabled"))
    recipe.look = nil
    #expect(!visible().contains("look.enabled"))
}

private extension ParameterDefault {
    var constantString: String? {
        if case .constant(.string(let value)) = self { return value }
        return nil
    }
}

@Test func unknownStructuredValuesSurviveARoundTrip() throws {
    // A newer build may store an object or an array; that must not fail the whole
    // recipe, or reading the adjustment data back from Photos would lose everything.
    let json = """
    {"version":3,"inputDomain":"sdr","hdrSource":"expand",
     "values":{"future.local":{"mask":"sky","feather":0.4,"stops":[1,0.5]},"tone.exposure":0.25}}
    """
    let recipe = try Recipe.decode(Data(json.utf8))
    #expect(recipe.value(for: "future.local")?.objectValue?["mask"] == .string("sky"))
    #expect(recipe.value(for: "future.local")?.objectValue?["stops"]?.arrayValue == [.number(1), .number(0.5)])
    let restored = try Recipe.decode(try recipe.encoded())
    #expect(restored == recipe)
    #expect(try restored.encoded() == recipe.encoded(), "structured values are not stable")
}

@Test func engineScaleIsDeclaredPerParameter() throws {
    // R11-002: RAW tint reads signed and is passed through; the scale, not the
    // readout format, decides the engine unit.
    let rawTint = try #require(Adjustments.declaration("develop.tint"))
    #expect(rawTint.format == .signed && rawTint.scale == .direct)
    #expect(rawTint.engineValue(50) == 50)
    #expect(try #require(Adjustments.declaration("develop.temperature")).engineValue(5500) == 5500)
    #expect(try #require(Adjustments.declaration("tone.exposure")).engineValue(0.3) == 0.3)
    #expect(try #require(Adjustments.declaration("tone.shadows")).engineValue(50) == 0.5)
    #expect(try #require(Adjustments.declaration("hdr.strength")).engineValue(200) == 2)
    #expect(try #require(Adjustments.declaration("hdr.range")).engineValue(3) == 3)
    let contrast = try #require(Adjustments.declaration("tone.contrast"))
    #expect(contrast.scale == .contrast)
    #expect(contrast.engineValue(0) == 1)
    #expect(abs(contrast.engineValue(100) - 1.6) < 1e-12)
}

@Test func logLookSpacesAreAppendedAndRawOnly() throws {
    let ids = ["srgb", "p3", "rec709", "hlg", "pq", "slog3-sgamut3cine", "slog3-sgamut3",
               "vlog-vgamut", "flog2-fgamut", "logc3-awg3", "logc4-awg4", "clog3-cinemagamut"]
    let input = try #require(Adjustments.declaration("look.input"))
    let output = try #require(Adjustments.declaration("look.output"))
    #expect(input.options.map(\.id) == ids)
    #expect(output.options.map(\.id) == ids)
    let logs: Set<String> = ["slog3-sgamut3cine", "slog3-sgamut3", "vlog-vgamut", "flog2-fgamut",
                             "logc3-awg3", "logc4-awg4", "clog3-cinemagamut"]
    for option in input.options {
        #expect(option.domains == (logs.contains(option.id) ? [.rawEDR] : Set(InputDomain.allCases)))
    }
    #expect(output.options.allSatisfy { $0.domains == Set(InputDomain.allCases) })
}

@Test func rangeCeilingAppliesToGeneratedHDROnly() throws {
    // R11-001: three stops cap the HDR we generate (sdr expansion, rawEDR); hdr and
    // dual keep their own headroom up to the declared four stops.
    #expect(Adjustments.generatedRangeCeiling == 3)
    let range = try #require(Adjustments.declaration("hdr.range"))
    #expect(range.defaultValue(in: .hdr) == .auto)
    #expect(range.range == 0.5...4)
}

@Test func filmFamiliesCoverTheStocksInMenuOrder() {
    #expect(Adjustments.filmStocks.first == "none")
    #expect(Array(Adjustments.filmStocks.dropFirst()) == Adjustments.filmFamilies.flatMap(\.stocks))
    #expect(Adjustments.filmFamilies.map(\.family) == FilmFamily.allCases)
    #expect(Adjustments.filmFamily("none") == nil && Adjustments.filmFamily("velvia100") == .slide)
}

@Test func filmAndImportedLUTAreAlternativeLooks() throws {
    var recipe = Recipe(inputDomain: .rawEDR)
    recipe.setValue(.string("portra400"), for: Recipe.filmID)
    let film = recipe
    recipe.look = LUTReference(contentHash: "sha256:01", name: "Look")
    #expect(recipe.conditionValue(Recipe.filmID) == .string("none"))
    #expect(recipe.look != nil)
    recipe.setValue(.string("portra400"), for: Recipe.filmID)
    #expect(recipe == film)
    #expect(try Recipe.decode(recipe.encoded()) == recipe)
}

@Test func onlyPartialRAWSceneLooksNeedTheSecondDevelopment() {
    let look = LUTReference(contentHash: "sha256:01", name: "Log")
    var recipe = Recipe(inputDomain: .rawEDR, look: look, values: [
        "look.input": .string("logc4-awg4"), "look.output": .string("rec709")])
    #expect(!recipe.needsLookBaseline)
    recipe.setValue(.number(40), for: "look.strength")
    #expect(recipe.needsLookBaseline)
    recipe.setValue(.bool(false), for: "look.enabled")
    #expect(!recipe.needsLookBaseline)
    recipe.setValue(nil, for: "look.enabled")
    recipe.setValue(.string("srgb"), for: "look.input")
    #expect(!recipe.needsLookBaseline)
    recipe.setValue(.string("portra400"), for: Recipe.filmID)
    recipe.setValue(.number(40), for: "look.filmStrength")
    #expect(recipe.needsLookBaseline)
    recipe.setValue(.number(0), for: "look.filmStrength")
    #expect(!recipe.needsLookBaseline)
    for id in Adjustments.effectIDs {
        recipe.setValue(.number(100), for: id)
        #expect(recipe.needsLookBaseline)
        recipe.setValue(nil, for: id)
        #expect(!recipe.needsLookBaseline)
    }
    recipe.setValue(.number(40), for: "look.filmStrength")
    recipe.setInputDomain(.sdr)
    #expect(!recipe.needsLookBaseline)
}

@Test func rawDecoderVersionIsOptionalSourceMetadata() throws {
    let legacy = try Recipe.decode(Data("{\"version\":1,\"inputDomain\":\"rawEDR\"}".utf8))
    #expect(legacy.rawDecoderVersion == nil)
    #expect(!String(decoding: try legacy.encoded(), as: UTF8.self).contains("rawDecoderVersion"))
    for version in ["8", "9", "8.dng", "9.dng", "future-version"] {
        let recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: version)
        #expect(try Recipe.decode(recipe.encoded()) == recipe)
        #expect(recipe.visibleParameters.map(\.id) == legacy.visibleParameters.map(\.id))
        #expect(Recipe(adjustmentData: try recipe.adjustmentData())?.rawDecoderVersion == version)
    }
}

@Test func sdrCurveRecipeRoundTrip() throws {
    let curve = try ToneCurve([0,0, 0.3,0.2, 0.7,0.8, 1,1])
    var recipe = Recipe()
    recipe.setValue(curve.parameterValue, for: "tone.curve")
    let restored = try Recipe.decode(Data(recipe.jsonString().utf8))
    #expect(restored.value(for: "tone.curve") == curve.parameterValue)
    recipe.setValue(ToneCurve().parameterValue, for: "tone.curve")
    #expect(recipe.value(for: "tone.curve") == nil)
    #expect(throws: ToneCurve.Error.invalidPoints) { try ToneCurve([0,0, 0.8,0.4, 0.2,0.6, 1,1]) }
}

@Test func rawCompatibilityIsAdditiveSourceMetadata() throws {
    let legacy = try Recipe.decode(Data("{\"version\":1,\"inputDomain\":\"rawEDR\"}".utf8))
    #expect(legacy.rawCompatibility == nil)
    #expect(!legacy.rawEmbeddedPreview)
    let legacyJSON = String(decoding: try legacy.encoded(), as: UTF8.self)
    #expect(!legacyJSON.contains("rawCompatibility"))
    #expect(!legacyJSON.contains("rawEmbeddedPreview"))

    let converted = Recipe(inputDomain: .rawEDR, rawDecoderVersion: "9.dng",
                           rawCompatibility: "libraw-0.22.0/dng-1")
    #expect(try Recipe.decode(converted.encoded()) == converted)
    #expect(Recipe(adjustmentData: try converted.adjustmentData())?.rawCompatibility == "libraw-0.22.0/dng-1")

    let preview = Recipe(inputDomain: .sdr, rawEmbeddedPreview: true)
    #expect(try Recipe.decode(preview.encoded()) == preview)
    #expect(String(decoding: try preview.encoded(), as: UTF8.self).contains("rawEmbeddedPreview"))
}

@Test func sharedParametricCurveIsMonotoneAndKeepsItsEndpoints() {
    #expect(ParametricCurve.value(at: 0.4) == 0.4)
    let samples = (0...100).map { ParametricCurve.value(at: Double($0)/100, highlights: 60, lights: 80, darks: -50, shadows: -70) }
    #expect(samples.first == 0 && samples.last == 1)
    #expect(zip(samples,samples.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(ParametricCurve.value(at: 0.6,lights: 100) > 0.6)
    #expect(ParametricCurve.value(at: 2,highlights: 100) == 2)
}
