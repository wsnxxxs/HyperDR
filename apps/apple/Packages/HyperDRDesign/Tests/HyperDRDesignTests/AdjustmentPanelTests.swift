import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRDesign

/// P7-2a: the controls come from the recipe's declarations, read and write
/// through `Recipe`, and their words are all in the catalogue.

private let english = Locale(identifier: "en")
private let context = AdjustmentContext(
    sourceValues: ["develop.temperature": 5600, "develop.tint": 4, "develop.luminanceNR": 30],
    automaticValues: ["hdr.range": 2.4],
    capabilities: ["CIRAWFilter.isLuminanceNoiseReductionSupported", "CIRAWFilter.isLensCorrectionSupported"],
    unavailableOptions: ["hdr.source": ["ai"]],
    luts: [LUTReference(contentHash: "sha256:01", name: "Kodak 2383")])
private let panel = AdjustmentPanel(context: context)

private func ids(_ recipe: Recipe, _ group: AdjustmentGroupID) -> [String] {
    panel.group(group: group, in: recipe)?.controls.map(\.id) ?? []
}

// MARK: Declaration → control

@Test func everyNumberBecomesASliderWithTheDeclaredRangeStepAndOrigin() throws {
    let recipe = Recipe(inputDomain: .rawEDR)
    for declaration in Adjustments.all where declaration.kind == .float || declaration.kind == .floatOrAuto {
        let control = panel.control(declaration, in: recipe)
        let spec = try #require(control.spec, "\(declaration.id) has no slider")
        #expect(spec.range == declaration.range)
        #expect(spec.step == declaration.step)
        #expect(spec.origin == (declaration.origin == .zero ? 0 : spec.range.lowerBound), "\(declaration.id)")
        #expect((spec.automatic != nil) == (declaration.kind == .floatOrAuto), "\(declaration.id)")
    }
    for declaration in Adjustments.all where declaration.kind != .float && declaration.kind != .floatOrAuto {
        #expect(panel.control(declaration, in: recipe).spec == nil, "\(declaration.id) is not a slider")
    }
}

@Test func defaultsAreTheDeclaredConstantTheSourceOrAuto() throws {
    let recipe = Recipe(inputDomain: .rawEDR)
    let exposure = try #require(panel.control("tone.exposure", in: recipe))
    #expect(exposure.value == .number(0) && exposure.isDefault)
    #expect(exposure.spec?.defaultValue == 0)
    let coverage = try #require(panel.control("hdr.coverage", in: recipe))
    #expect(coverage.value == .number(60), "C1: area coverage 0.6, declared as 60 %")
    let temperature = try #require(panel.control("develop.temperature", in: recipe))
    #expect(temperature.value == .number(5600) && temperature.defaultNumber == 5600)
    let range = try #require(panel.control("hdr.range", in: recipe))
    #expect(range.value == .automatic(resolved: 2.4) && range.isAutomatic)
    #expect(range.readout(locale: english) == "Auto · 2.4")
    let start = try #require(panel.control("hdr.expansionStart", in: recipe))
    #expect(start.value == .automatic(resolved: nil))
    #expect(start.readout(locale: english) == "Auto")
}

@Test func aSourceValueNotReportedYetIsShownButUnavailable() throws {
    let control = try #require(panel.control("develop.sharpness", in: Recipe(inputDomain: .rawEDR)))
    #expect(control.value == .unknown && !control.isAvailable)
}

@Test func readoutsFollowTheDeclaredFormat() throws {
    var recipe = Recipe(inputDomain: .rawEDR)
    panel.set("tone.exposure", number: 0.3, in: &recipe)
    panel.set("tone.contrast", number: -12, in: &recipe)
    panel.set("hdr.coverage", number: 45, in: &recipe)
    panel.set("hdr.range", number: 2, in: &recipe)
    panel.set("develop.temperature", number: 12_000, in: &recipe)
    let readout = { (id: String) in panel.control(id, in: recipe)?.readout(locale: english) }
    #expect(readout("tone.exposure") == "+0.30")
    #expect(readout("tone.contrast") == "−12" || readout("tone.contrast") == "-12")
    #expect(readout("hdr.coverage") == "45%")
    #expect(readout("hdr.range") == "2.0")
    #expect(readout("develop.temperature") == "12000")
}

// MARK: Display conditions

@Test func groupsAndControlsFollowTheInputDomain() {
    let sdr = Recipe(inputDomain: .sdr)
    #expect(panel.groups(for: sdr).map(\.group) == [.hdr, .light, .color, .look], "no detail group outside RAW")
    let mixer = HSLBand.allCases.flatMap { band in HSLComponent.allCases.map { "hsl.\(band.rawValue).\($0.rawValue)" } }
    let grading = ColorGradingZone.allCases.flatMap { zone in HSLComponent.allCases.map { "grade.\(zone.rawValue).\($0.rawValue)" } } + ["grade.blending","grade.balance"]
    #expect(ids(sdr, .color) == ["color.warmth", "color.tint", "color.vibrance", "color.saturation"] + mixer + grading)
    #expect(ids(sdr, .look) == ["look.lut", "look.film", "effect.grain", "effect.halation"],
            "grain and halation on every photo, without a look, after the looks")
    #expect(ids(sdr, .hdr).contains("hdr.coverage"))
    #expect(!ids(sdr, .hdr).contains("hdr.sdrRolloff"))

    let raw = Recipe(inputDomain: .rawEDR)
    #expect(panel.groups(for: raw).map(\.group) == [.hdr, .light, .color, .look, .detail])
    #expect(ids(raw, .color).prefix(2) == ["develop.temperature", "develop.tint"])
    #expect(ids(raw, .hdr).contains("hdr.sdrRolloff"))

    let dual = Recipe(inputDomain: .dual)
    #expect(!ids(dual, .hdr).contains("hdr.expansionStart"))
    let source = panel.control("hdr.source", in: dual)
    #expect(source?.options.map(\.id) == ["builtIn"], "an HDR photo's source is a line, not a choice")
}

@Test func capabilitiesHideControlsTheSourceCannotDo() {
    let raw = Recipe(inputDomain: .rawEDR)
    #expect(ids(raw, .detail) == ["develop.luminanceNR", "develop.lensCorrection"])
    #expect(!ids(Recipe(inputDomain: .sdr), .hdr).contains("hdr.model"), "one model: no model choice")
}

@Test func aLensCorrectionTheDecoderDoesNotOfferIsShownUnavailable() throws {
    let raw = Recipe(inputDomain: .rawEDR)
    #expect(panel.group(group: .detail, in: raw)?.unsupported.isEmpty == true, "lens correction is offered")
    let bare = AdjustmentPanel(context: AdjustmentContext(capabilities: ["CIRAWFilter.isLuminanceNoiseReductionSupported"]))
    let detail = try #require(bare.group(group: .detail, in: raw))
    #expect(detail.unsupported.map(\.id) == ["develop.lensCorrection"], "missing sliders are not listed")
    #expect(!detail.controls.map(\.id).contains("develop.lensCorrection"))
    #expect(panel.group(group: .hdr, in: Recipe(inputDomain: .sdr))?.unsupported.isEmpty == true)
    #expect(bare.group(group: .detail, in: Recipe(inputDomain: .sdr)) == nil, "no detail group off RAW")
}

@Test func theHDRSwitchSitsInTheHeaderAndHidesTheGroup() throws {
    var recipe = Recipe(inputDomain: .sdr)
    let on = try #require(panel.group(group: .hdr, in: recipe))
    #expect(on.headerToggle?.id == "hdr.enabled" && on.headerToggle?.isOn == true)
    #expect(!on.controls.map(\.id).contains("hdr.enabled"))
    #expect(on.affectsHDROnly)
    panel.set("hdr.enabled", isOn: false, in: &recipe)
    let off = try #require(panel.group(group: .hdr, in: recipe))
    #expect(off.isSwitchedOff && off.controls.isEmpty)
    #expect(off.isModified, "the switch itself is a change")
    #expect(panel.group(group: .look, in: recipe)?.headerToggle == nil, "the LUT switch is a row")
}

@Test func lookControlsAppearOnceALUTIsChosen() {
    var recipe = Recipe(inputDomain: .sdr)
    #expect(ids(recipe, .look) == ["look.lut", "look.film", "effect.grain", "effect.halation"])
    panel.set("look.lut", reference: "sha256:01", in: &recipe)
    #expect(recipe.look?.name == "Kodak 2383")
    #expect(ids(recipe, .look) == ["look.lut", "look.enabled", "look.strength", "look.input", "look.output", "look.film", "effect.grain", "effect.halation"])
    #expect(AdjustmentText.summary(panel.group(group: .look, in: recipe)!, locale: english) == "Kodak 2383")
    let input = panel.control("look.input", in: recipe)
    #expect(input?.options.contains { $0.id == "slog3-sgamut3cine" } == false, "S-Log3 input is RAW only")
    #expect(input?.options.contains { AdjustmentText.LookSpaceFamily($0.id) == .log } == false, "Log input is RAW only")
}

@Test func filmStrengthAppearsOnceAFilmIsChosen() throws {
    var recipe = Recipe(inputDomain: .sdr)
    panel.set(Recipe.filmID, option: "velvia100", in: &recipe)
    #expect(ids(recipe, .look) == ["look.lut", "look.film", "look.filmExposure", "look.filmStrength", "look.filmAntihalation", "effect.grain", "effect.halation"])
    let film = try #require(panel.control(Recipe.filmID, in: recipe))
    let sections = AdjustmentText.optionSections(film)
    #expect(sections.allSatisfy { $0.family == nil }, "film stocks are not LUT spaces")
    #expect(sections.map(\.filmFamily) == [nil, .negative, .slide, .cinema])
    #expect(sections[0].options.map(\.id) == ["none"])
    #expect(sections.flatMap { $0.options.map(\.id) } == Adjustments.filmStocks)
    panel.set(Recipe.filmID, option: "none", in: &recipe)
    #expect(ids(recipe, .look) == ["look.lut", "look.film", "effect.grain", "effect.halation"])
}

@Test func grainAndHalationWorkWithALUTAndWithoutALook() {
    var recipe = Recipe(inputDomain: .hdr)
    panel.set("effect.grain", number: 40, in: &recipe)
    panel.set("effect.halation", number: 25, in: &recipe)
    #expect(recipe.value(for: "effect.grain") == .number(40))
    panel.set("look.lut", reference: "sha256:01", in: &recipe)
    #expect(ids(recipe, .look).suffix(2) == ["effect.grain", "effect.halation"], "a LUT leaves them alone")
    #expect(recipe.value(for: "effect.halation") == .number(25))
    panel.set("look.lut", reference: nil, in: &recipe)
    #expect(recipe.value(for: "effect.grain") == .number(40), "removing the look keeps them")
}

@Test func aStockOnAnUntouchedPhotoBringsItsOwnGrainAndHalation() {
    var recipe = Recipe(inputDomain: .sdr)
    panel.set("look.lut", reference: "sha256:01", in: &recipe)
    panel.set(Recipe.filmExposureID, number: 1, in: &recipe)
    panel.chooseFilm("portra400", in: &recipe)
    #expect(recipe.look == nil, "a film replaces the LUT")
    #expect(recipe.isDefault(Recipe.filmExposureID), "its exposure is back on the meter")
    #expect(recipe.value(for: "effect.grain") == .number(100))
    #expect(recipe.value(for: "effect.halation") == .number(100))

    // Another stock keeps what the photo has, even no grain at all.
    panel.set("effect.grain", number: 0, in: &recipe)
    panel.set(Recipe.filmExposureID, number: 2.7, in: &recipe)
    panel.chooseFilm("velvia100", in: &recipe)
    #expect(recipe.isDefault("effect.grain") && recipe.value(for: "effect.halation") == .number(100))
    #expect(recipe.value(for: Recipe.filmExposureID) == .number(2.7), "another stock keeps a manual exposure")

    // Effects already set are never overwritten by a stock.
    var set = Recipe(inputDomain: .sdr)
    panel.set("effect.grain", number: 30, in: &set)
    panel.chooseFilm("gold200", in: &set)
    #expect(set.value(for: "effect.grain") == .number(30) && set.isDefault("effect.halation"))

    panel.chooseFilm("none", in: &recipe)
    #expect(recipe.conditionValue(Recipe.filmID) == .string("none"))
    #expect(recipe.value(for: "effect.halation") == .number(100), "no look still has its effects")
    panel.chooseFilm("portra160", in: &recipe)
    #expect(recipe.isDefault(Recipe.filmExposureID), "a stock after none starts on the meter again")
}

@Test func choosingALUTStartsItsSpacesFromTheLibrary() {
    let panel = AdjustmentPanel(context: AdjustmentContext(
        luts: [LUTReference(contentHash: "sha256:01", name: "Kodak 2383"),
               LUTReference(contentHash: "sha256:02", name: "Venice"),
               LUTReference(contentHash: "sha256:03", name: "Unrecorded")],
        lookSpaces: ["sha256:01": AdjustmentLookSpaces(input: "p3", output: "hlg"),
                     "sha256:02": AdjustmentLookSpaces(input: "slog3-sgamut3", output: "rec709")]))

    var sdr = Recipe(inputDomain: .sdr)
    panel.set("look.lut", reference: "sha256:01", in: &sdr)
    #expect(sdr.conditionValue("look.input") == .string("p3"))
    #expect(sdr.conditionValue("look.output") == .string("hlg"))

    // A Log input is RAW only. The choice is disabled, and a stale binding
    // write cannot replace the existing valid look or relabel the Log LUT.
    let previous = sdr
    #expect(panel.control("look.lut", in: sdr)?.disabledOptions.contains("sha256:02") == true)
    panel.set("look.lut", reference: "sha256:02", in: &sdr)
    #expect(sdr == previous)

    var raw = Recipe(inputDomain: .rawEDR)
    panel.set("look.lut", reference: "sha256:02", in: &raw)
    #expect(raw.conditionValue("look.input") == .string("slog3-sgamut3"))

    // A LUT the library records no spaces for, and removing the LUT, leave them alone.
    panel.set("look.lut", reference: "sha256:03", in: &raw)
    #expect(raw.look?.name == "Unrecorded" && raw.conditionValue("look.input") == .string("slog3-sgamut3"))
    panel.set("look.lut", reference: nil, in: &raw)
    #expect(raw.look == nil && raw.conditionValue("look.output") == .string("rec709"))
}

@Test func lutSpaceMenusGroupDisplayHDRLogAndGrading() {
    var raw = Recipe(inputDomain: .rawEDR)
    panel.set("look.lut", reference: "sha256:01", in: &raw)
    let input = panel.control("look.input", in: raw)!
    let sections = AdjustmentText.optionSections(input)
    #expect(sections.map(\.family) == [.display, .hdr, .log, .grading])
    #expect(sections[0].options.map(\.id) == ["srgb", "p3", "rec709", "rec2020"])
    #expect(sections[1].options.map(\.id) == ["hlg", "pq"])
    #expect(sections[3].options.map(\.id) == ["davinci-dwg", "acescct-ap1"])
    #expect(sections.flatMap(\.options).count == input.options.count)
    // Outside RAW the input has no Log or grading section; the output keeps all four.
    var sdr = Recipe(inputDomain: .sdr)
    panel.set("look.lut", reference: "sha256:01", in: &sdr)
    #expect(AdjustmentText.optionSections(panel.control("look.input", in: sdr)!).map(\.family) == [.display, .hdr])
    #expect(AdjustmentText.optionSections(panel.control("look.output", in: sdr)!).map(\.family) == [.display, .hdr, .log, .grading])
    #expect(AdjustmentText.optionSections(panel.control("hdr.source", in: sdr)!).map(\.family) == [nil])
}

// MARK: Edits and reset

@Test func editsGoThroughTheRecipeAndSnapToTheStep() {
    var recipe = Recipe(inputDomain: .sdr)
    panel.set("tone.exposure", number: 0.304, in: &recipe)
    #expect(recipe.value(for: "tone.exposure") == .number(0.3))
    panel.set("tone.exposure", number: 9, in: &recipe)
    #expect(recipe.value(for: "tone.exposure") == .number(4), "clamped to the range")
    panel.set("tone.exposure", number: 0, in: &recipe)
    #expect(recipe.value(for: "tone.exposure") == nil, "the default is not stored")
}

@Test func theSourceValueIsNotStoredAsAnOverride() {
    var recipe = Recipe(inputDomain: .rawEDR)
    panel.set("develop.temperature", number: 6500, in: &recipe)
    #expect(recipe.value(for: "develop.temperature") == .number(6500))
    #expect(panel.control("develop.temperature", in: recipe)?.isDefault == false)
    panel.set("develop.temperature", number: 5600, in: &recipe)
    #expect(recipe.value(for: "develop.temperature") == nil)
    #expect(panel.control("develop.temperature", in: recipe)?.isDefault == true)

    // A source value off the step grid is still reachable: within half a step is the source.
    let offGrid = AdjustmentPanel(context: AdjustmentContext(sourceValues: ["develop.temperature": 5612]))
    offGrid.set("develop.temperature", number: 5612, in: &recipe)
    #expect(recipe.value(for: "develop.temperature") == nil)
    offGrid.set("develop.temperature", number: 5600, in: &recipe)
    #expect(recipe.value(for: "develop.temperature") == nil)
    offGrid.set("develop.temperature", number: 5650, in: &recipe)
    #expect(recipe.value(for: "develop.temperature") == .number(5650))
}

@Test func theAutoSentinelReturnsToAuto() throws {
    var recipe = Recipe(inputDomain: .sdr)
    let spec = try #require(panel.control("hdr.range", in: recipe)?.spec)
    panel.set("hdr.range", sliderValue: 3, in: &recipe)
    #expect(recipe.value(for: "hdr.range") == .number(3))
    panel.set("hdr.range", sliderValue: spec.automatic!.value, in: &recipe)
    #expect(recipe.value(for: "hdr.range") == nil)
    #expect(panel.control("hdr.range", in: recipe)?.isAutomatic == true)
    #expect(spec.automatic?.resume == 2.4, "leaving Auto starts from the resolved value")
}

@Test func onlyOfferedAndAvailableOptionsCanBeChosen() {
    var recipe = Recipe(inputDomain: .sdr)
    panel.set("hdr.source", option: "ai", in: &recipe)
    #expect(recipe.hdrSource == .expand, "AI is unavailable here")
    panel.set("hdr.source", option: "captured", in: &recipe)
    #expect(recipe.hdrSource == .expand, "captured is not an SDR option")
    var raw = Recipe(inputDomain: .rawEDR)
    panel.set("hdr.source", option: "capturedExpand", in: &raw)
    #expect(raw.hdrSource == .capturedExpand)
}

@Test func resetOneGroupOrAll() {
    var recipe = Recipe(inputDomain: .rawEDR)
    panel.set("tone.exposure", number: 1, in: &recipe)
    panel.set("tone.shadows", number: 20, in: &recipe)
    panel.set("color.vibrance", number: 10, in: &recipe)
    panel.set("hdr.enabled", isOn: false, in: &recipe)
    panel.set("hdr.strength", number: 150, in: &recipe)
    panel.set("look.lut", reference: "sha256:01", in: &recipe)

    panel.reset("tone.exposure", in: &recipe)
    #expect(recipe.isDefault("tone.exposure") && !recipe.isDefault("tone.shadows"))

    let hdr = panel.group(group: .hdr, in: recipe)!
    #expect(hdr.modified.map(\.id) == ["hdr.enabled", "hdr.strength"], "hidden by the switch, still counted")
    panel.reset(group: .hdr, in: &recipe)
    #expect(recipe.isDefault("hdr.enabled") && recipe.isDefault("hdr.strength"))
    #expect(!recipe.isDefault("color.vibrance"))

    recipe.setValue(.number(1), for: "future.parameter")
    panel.resetAll(in: &recipe)
    #expect(panel.groups(for: recipe).allSatisfy { !$0.isModified })
    #expect(recipe.look == nil)
    #expect(recipe.value(for: "future.parameter") == .number(1), "unknown ids are kept")
}

// MARK: Summary and ring

@Test func aCollapsedGroupSumsUpItsChanges() {
    var recipe = Recipe(inputDomain: .sdr)
    let light = { panel.group(group: .light, in: recipe)! }
    #expect(AdjustmentText.summary(light(), locale: english) == "No changes")
    panel.set("tone.exposure", number: 0.3, in: &recipe)
    panel.set("tone.contrast", number: 10, in: &recipe)
    panel.set("tone.blacks", number: 5, in: &recipe)
    #expect(AdjustmentText.summary(light(), locale: english) == "Exposure +0.30 · Contrast +10 · +1")
    let detail = panel.group(group: .detail, in: Recipe(inputDomain: .rawEDR))!
    #expect(AdjustmentText.summary(detail, locale: english) == "Lens correction on")
    var off = Recipe(inputDomain: .sdr)
    panel.set("hdr.enabled", isOn: false, in: &off)
    #expect(AdjustmentText.summary(panel.group(group: .hdr, in: off)!, locale: english) == "HDR off")
    var ai = Recipe(inputDomain: .sdr)
    ai.setHDRSource(.ai)
    #expect(AdjustmentText.summary(panel.group(group: .hdr, in: ai)!, locale: english) == "Source AI")
}

@Test func theRingShowsTheDeviationFromTheDefault() {
    var recipe = Recipe(inputDomain: .sdr)
    panel.set("tone.exposure", number: 2, in: &recipe)
    #expect(panel.control("tone.exposure", in: recipe)?.deviation == 0.5)
    panel.set("tone.exposure", number: -4, in: &recipe)
    #expect(panel.control("tone.exposure", in: recipe)?.deviation == -1)
    panel.set("hdr.strength", number: 150, in: &recipe)
    #expect(panel.control("hdr.strength", in: recipe)?.deviation == 0.5, "from 100 % towards 200 %")
    #expect(panel.control("hdr.range", in: recipe)?.deviation == 0, "Auto")
}

// MARK: Words

@Test func theColorGroupsResetNamesWhatItResets() {
    let chinese = Locale(identifier: "zh-Hans")
    #expect(DesignStrings.string("group.color", locale: chinese) == "颜色")
    #expect(AdjustmentText.undoName(.group(.color), locale: english) == "Reset Color")
    #expect(AdjustmentText.undoName(.group(.color), locale: chinese) == "重置颜色")
    #expect(AdjustmentText.undoName(.group(.look), locale: chinese) == "重置风格", "grain and halation go with the look")
    #expect(AdjustmentText.undoName(.group(.light), locale: chinese) == "重置光线")
    #expect(AdjustmentText.undoName(.all, locale: english) == "Reset All")
}

@Test func everyDeclaredKeyIsInTheCatalogueInBothLanguages() {
    let keys = AdjustmentText.declaredKeys
    // `21 * 2`: the twenty-one LUT spaces, for look.input and look.output; then the film stocks.
    #expect(keys.count == Adjustments.all.count * 3 + 6 + 21 * 2 + Adjustments.filmStocks.count + 5)
    for locale in [english, Locale(identifier: "zh-Hans")] {
        for key in keys.sorted() {
            #expect(DesignStrings.string(key, locale: locale) != key, "\(key) missing in \(locale.identifier)")
        }
    }
    #expect(DesignStrings.string("ctrl.tone.blacks.label", locale: Locale(identifier: "zh-Hans")) == "黑点")
}

// MARK: Touch math

@Test func fineTuneSlowsDownAwayFromTheTrack() {
    #expect(FineTune(verticalDistance: 39) == .full)
    #expect(FineTune(verticalDistance: -40) == .half)
    #expect(FineTune(verticalDistance: 100) == .quarter)
    #expect(DefaultDetent.apply(0.012, defaultValue: 0, pointsPerUnit: 125) == 0, "1.5 pt from the default")
    #expect(DefaultDetent.apply(0.02, defaultValue: 0, pointsPerUnit: 125) == 0.02)
}

@Test func theRulerIsATapeUnderAFixedNeedle() throws {
    let control = try #require(panel.control("tone.exposure", in: Recipe(inputDomain: .sdr)))
    let ruler = try #require(RulerScale(control, width: 400))
    #expect(ruler.pointsPerUnit == 75, "4 EV, the larger side, over a reach of 300 pt")
    #expect(ruler.offset(of: 1, needle: 0) == 75 && ruler.offset(of: -4, needle: 0) == -300)
    #expect(ruler.majorTick == 1 && ruler.minorTick == 0.1)
    #expect(ruler.value(from: 0, translation: -75) == 1, "the tape follows the finger: left raises the value")
    #expect(ruler.value(from: 0, translation: 75, speed: 0.25) == -0.25)
    #expect(ruler.value(from: 3.5, translation: -500) == 4)
    #expect(ruler.value(from: 0, translation: -4) == 0, "the default holds within 5 pt")
    #expect(ruler.value(from: 0, translation: 5, speed: 0.25) == 0, "5 pt of finger travel, also slowed down")
    #expect(ruler.settled(0.3049) == 0.3)
    #expect(ruler.crossing(from: -0.2, to: 0.2).defaultValue)
    #expect(ruler.crossing(from: 0.8, to: 1.1).majorTick)
    #expect(ruler.crossing(from: 3.9, to: 4).limit && !ruler.crossing(from: 3.9, to: 4).majorTick)
    #expect(!ruler.crossing(from: 0.2, to: 0.4).any)
    #expect(ruler.ticks.first?.value == -4 && ruler.ticks.last?.value == 4)
    #expect(ruler.ticks.filter(\.isMajor).count == 9)
    #expect(RulerScale(control, width: 120)?.pointsPerUnit == 65, "a narrow ruler keeps a reach of 260 pt")

    let temperature = try #require(panel.control("develop.temperature", in: Recipe(inputDomain: .rawEDR)))
    let kelvin = try #require(RulerScale(temperature, width: 400))
    #expect(kelvin.range == 1000...50000 && kelvin.spacing == .reciprocal)
    #expect(kelvin.pointsPerUnit == 0.6, "500 mired over a reach of 300 pt, whatever the as-shot default")
    #expect(kelvin.offset(of: 60_000, needle: 50_000) == 0, "a source value past the range sits at its end")
    // Mired, not kelvin: 2000 → 4000 K and 4000 K → the cool end are the same reach.
    #expect(abs(kelvin.offset(of: 4000, needle: 2000) - 150) < 1e-9)
    #expect(abs(kelvin.offset(of: 2000, needle: 1000) - 300) < 1e-9)
    #expect(abs(kelvin.value(from: 5000, translation: -60) - 1e6 / 100) < 1e-6, "200 → 100 mired")
    let ticks = kelvin.ticks
    #expect(ticks.first?.value == 1000 && ticks.last?.value == 50000)
    #expect(zip(ticks, ticks.dropFirst()).allSatisfy { kelvin.offset(of: $1.value, needle: $0.value) >= 3 })
    #expect(ticks.filter(\.isMajor).map(\.value).starts(with: [1000, 2000, 3000, 4000, 5000]))
    #expect(!kelvin.crossing(from: 30_100, to: 30_900).majorTick, "no tick every 1000 K at the cool end")
    #expect(kelvin.crossing(from: 5900, to: 6100).majorTick)
}

/// The kelvin slider spreads its 1000…50000 K in mired: 6500 K sits near the
/// middle, and a step looks the same warm or cool.
@Test func kelvinSlidersSpreadInMired() throws {
    var recipe = Recipe(inputDomain: .rawEDR)
    panel.set("develop.temperature", number: 5000, in: &recipe)
    let control = try #require(panel.control("develop.temperature", in: recipe))
    let spec = try #require(control.spec)
    #expect(spec.spacing == .reciprocal && spec.range == 1000...50000)
    #expect(spec.fraction(of: 1000) == 0 && spec.fraction(of: 50000) == 1)
    let mid = spec.value(atFraction: 0.5)
    #expect(abs(mid - 1e6 / 510) < 50, "half way is 510 mired, about 1950 K")
    #expect(abs(spec.fraction(of: 2000) - 500.0 / 980) < 1e-9)
    #expect(spec.value(atFraction: spec.fraction(of: 6500)) == 6500)
    // A relative drag moves in mired and holds at the default.
    let cooler = spec.dragged(from: 5000, by: 49, length: 490)
    #expect(abs(1e6 / cooler - (200 - 98)) < 1, "a tenth of the track is 98 mired")
    let tint = try #require(panel.control("develop.tint", in: recipe)?.spec)
    #expect(tint.range == -200...200 && tint.spacing == .linear)
    #expect(tint.dragged(from: 0, by: 49, length: 490) == 40, "linear tracks keep their feel")
}

/// 0…100 from 0, ±100 from 0 and 0…100 from 100 follow one rule: the tape
/// stops at the bounds, and each default is one reach from its far end.
@Test func everyRangeShapeFollowsTheSameRule() throws {
    let recipe = Recipe(inputDomain: .hdr)
    func scale(_ id: String) throws -> RulerScale {
        let control = try #require(panel.control(id, in: recipe))
        return try #require(RulerScale(control, width: 400))
    }
    let signed = try scale("color.vibrance"), upward = try scale("hdr.sdrRolloff"), downward = try scale("look.strength")
    #expect(signed.defaultValue == 0 && upward.defaultValue == 0 && downward.defaultValue == 100)
    #expect(signed.pointsPerUnit == 3 && upward.pointsPerUnit == 3 && downward.pointsPerUnit == 3, "the same feel")
    // Where the bounds sit, with the needle at the default.
    #expect(signed.offset(of: -100, needle: 0) == -300 && signed.offset(of: 100, needle: 0) == 300)
    #expect(upward.offset(of: 0, needle: 0) == 0 && upward.offset(of: 100, needle: 0) == 300, "tape on the right only")
    #expect(downward.offset(of: 0, needle: 100) == -300 && downward.offset(of: 100, needle: 100) == 0,
            "tape on the left only")
    // The same gesture means the same thing everywhere: left raises, right lowers, the bounds hold.
    #expect(upward.value(from: 0, translation: 30) == 0 && upward.value(from: 0, translation: -30) == 10)
    #expect(downward.value(from: 100, translation: -30) == 100 && downward.value(from: 100, translation: 30) == 90)
    #expect(signed.value(from: 0, translation: 30) == -10 && signed.value(from: 0, translation: -30) == 10)
    #expect(signed.minorTick == 2.5, "a quarter of a major tick: 7.5 pt apart")
    // 1 % is the same distance on every percent control, wider ranges included.
    // An Auto default is what Auto resolves to, so the dot and the lit span have somewhere to be.
    let range = try scale("hdr.range")
    #expect(range.defaultValue == 2.4 && range.value(from: 2.4, translation: -4) == 2.4)
    let strength = try scale("hdr.strength")
    #expect(strength.pointsPerUnit == 3 && strength.offset(of: 200, needle: 100) == 300)
}
