import AppKit
import HyperDRRecipe
import SwiftUI
import Testing
@testable import HyperDRDesign

/// F2: the readout is the place to type an exact value. Every generated
/// slider takes what its readout would be given (the text the value box edits
/// as, a number at either end, a number beyond the range, the word for Auto)
/// through the same parse and write the box performs on Return.

private let context = AdjustmentContext(
    sourceValues: ["develop.temperature": 5600, "develop.tint": 4, "develop.luminanceNR": 30,
                   "develop.sharpness": 40, "develop.chromaNR": 10, "develop.moire": 0],
    automaticValues: ["hdr.range": 2.4],
    capabilities: ["CIRAWFilter.isLuminanceNoiseReductionSupported", "CIRAWFilter.isLensCorrectionSupported"])
private let panel = AdjustmentPanel(context: context)

/// What typing `text` into the box and pressing Return does to `recipe`.
private func type(_ text: String, into id: String, _ recipe: inout Recipe) {
    guard let spec = panel.control(id, in: recipe)?.spec, let new = spec.parse(text) else { return }
    panel.set(id, sliderValue: new, in: &recipe)
}

private func number(_ id: String, _ recipe: Recipe) -> Double? {
    guard case .number(let value) = panel.control(id, in: recipe)?.value else { return nil }
    return value
}

@Test func everySliderTakesTypedValuesAtBothEndsAndClampsBeyondThem() throws {
    let recipe = Recipe(inputDomain: .rawEDR)
    var checked = 0
    for declaration in Adjustments.all where declaration.kind == .float || declaration.kind == .floatOrAuto {
        let control = panel.control(declaration, in: recipe)
        let spec = try #require(control.spec)
        guard control.isAvailable else { continue }
        let scale = spec.format.scale
        let lower = spec.range.lowerBound, upper = spec.range.upperBound
        for (text, expected) in [(spec.editableText(upper), upper), (spec.editableText(lower), lower),
                                 ("\((upper * scale + 1000).rounded())", upper),
                                 ("\((lower * scale - 1000).rounded())", lower)] {
            var edited = recipe
            type(text, into: declaration.id, &edited)
            let stored = number(declaration.id, edited)
            #expect(stored != nil && abs(stored! - expected) < 1e-6,
                    "\(declaration.id): typing \(text) gave \(String(describing: stored)), not \(expected)")
        }
        checked += 1
    }
    #expect(checked > 20, "the loop covered the sliders")
}

@Test func temperatureAndTintTakeTheirFullRangeAsTyped() {
    var recipe = Recipe(inputDomain: .rawEDR)
    type("50000", into: "develop.temperature", &recipe)
    #expect(number("develop.temperature", recipe) == 50_000)
    type("1000 K", into: "develop.temperature", &recipe)
    #expect(number("develop.temperature", recipe) == 1000)
    type("+200", into: "develop.tint", &recipe)
    #expect(number("develop.tint", recipe) == 200)
    type("−200", into: "develop.tint", &recipe)
    #expect(number("develop.tint", recipe) == -200)
    type("12000", into: "develop.temperature", &recipe)
    #expect(number("develop.temperature", recipe) == 12_000)
    // The box shows and edits "+200" and "50000" in full.
    let tint = panel.control("develop.tint", in: recipe)?.spec
    #expect(tint?.editableText(200) == "200")
    #expect(tint?.formatted(200, locale: Locale(identifier: "en")).contains("200") == true)
    #expect(panel.control("develop.temperature", in: recipe)?.spec?.editableText(50_000) == "50000")
}

@Test func anAutomaticSliderTakesTheWordAnEmptyBoxAndANumber() throws {
    var recipe = Recipe(inputDomain: .rawEDR)
    type("2", into: "hdr.range", &recipe)
    #expect(number("hdr.range", recipe) == 2)
    type("auto", into: "hdr.range", &recipe)
    #expect(panel.control("hdr.range", in: recipe)?.isAutomatic == true)
    type("2.5", into: "hdr.range", &recipe)
    type("", into: "hdr.range", &recipe)
    #expect(panel.control("hdr.range", in: recipe)?.isAutomatic == true)
    type("自动", into: "hdr.range", &recipe)
    #expect(panel.control("hdr.range", in: recipe)?.isAutomatic == true)
}
