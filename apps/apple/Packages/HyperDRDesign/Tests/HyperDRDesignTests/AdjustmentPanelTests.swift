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
    #expect(ids(sdr, .color) == ["color.warmth", "color.tint", "color.vibrance", "color.saturation"])
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
    #expect(ids(recipe, .look) == ["look.lut"])
    panel.set("look.lut", reference: "sha256:01", in: &recipe)
    #expect(recipe.look?.name == "Kodak 2383")
    #expect(ids(recipe, .look) == ["look.lut", "look.enabled", "look.strength", "look.input", "look.output"])
    #expect(AdjustmentText.summary(panel.group(group: .look, in: recipe)!, locale: english) == "Kodak 2383")
    let input = panel.control("look.input", in: recipe)
    #expect(input?.options.contains { $0.id == "slog3-sgamut3cine" } == false, "S-Log3 input is RAW only")
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

@Test func everyDeclaredKeyIsInTheCatalogueInBothLanguages() {
    let keys = AdjustmentText.declaredKeys
    #expect(keys.count == Adjustments.all.count * 3 + 6 + 12 + 5)
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

@Test func theRulerSpansTwoAndAHalfWidths() throws {
    let control = try #require(panel.control("tone.exposure", in: Recipe(inputDomain: .sdr)))
    let ruler = try #require(RulerScale(control, referenceWidth: 400))
    #expect(ruler.pointsPerUnit == 125, "8 EV over 1000 pt")
    #expect(ruler.majorTick == 1 && ruler.minorTick == 0.1)
    #expect(ruler.value(from: 0, translation: -125) == 1, "dragging left raises the value")
    #expect(ruler.value(from: 3.5, translation: -500) == 4)
    #expect(ruler.settled(0.3049) == 0.3)
    #expect(ruler.settled(0.01) == 0, "the default holds within 2 pt")
    #expect(ruler.crossing(from: -0.2, to: 0.2).defaultValue)
    #expect(ruler.crossing(from: 0.8, to: 1.1).majorTick)
    #expect(!ruler.crossing(from: 0.2, to: 0.4).any)

    let temperature = try #require(panel.control("develop.temperature", in: Recipe(inputDomain: .rawEDR)))
    let kelvin = try #require(RulerScale(temperature, referenceWidth: 400))
    #expect(kelvin.majorTick == 1000 && kelvin.minorTick * kelvin.pointsPerUnit >= 4)
}
