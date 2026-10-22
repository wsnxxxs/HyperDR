import Foundation
import Testing
@testable import HyperDRDesign

private let brightness = ParameterSpec.signed(-2...2, step: 0.05, format: .signed(fractionDigits: 2, suffix: "EV"))
private let strength = ParameterSpec(range: 0...1, step: 0.05, defaultValue: 0.4, format: .percent)
private let contrast = ParameterSpec(range: 0.8...1.35, step: 0.01, defaultValue: 1, origin: 1,
                                     format: .number(fractionDigits: 2))

@Test func valuesSnapToTheStepFromTheLowerBound() {
    #expect(brightness.snapped(0.32) == 0.3)
    #expect(brightness.snapped(0.33) == 0.35)
    #expect(contrast.snapped(1.004) == 1)
    #expect(strength.snapped(1.7) == 1)
    #expect(strength.snapped(-0.2) == 0)
    // No floating-point residue from the step arithmetic.
    #expect(strength.stepped(0.25, by: 1) == 0.3)
}

@Test func steppingClampsAtTheEnds() {
    #expect(brightness.stepped(1.9, by: 10) == 2)
    #expect(brightness.stepped(-1.9, by: -10) == -2)
    #expect(strength.stepped(0.4, by: -1) == 0.35)
}

@Test func signedParametersFillFromTheirOrigin() {
    #expect(brightness.isCentred)
    #expect(!strength.isCentred)
    #expect(brightness.fill(for: 1) == 0.5...0.75)
    #expect(brightness.fill(for: -1) == 0.25...0.5)
    #expect(brightness.fill(for: 0) == 0.5...0.5)
    #expect(strength.fill(for: 0.4) == 0...0.4)
    #expect(contrast.fill(for: 0.8) == 0...contrast.fraction(of: 1))
}

@Test func trackPositionsRoundTrip() {
    #expect(brightness.value(atFraction: 0.5) == 0)
    #expect(brightness.value(atFraction: 1.3) == 2)
    #expect(strength.value(atFraction: 0.42) == 0.4)
}

@Test func readoutFormats() {
    #expect(brightness.formatted(0.3) == "+0.30 EV")
    #expect(brightness.formatted(-1) == "-1.00 EV")
    #expect(brightness.formatted(0.001) == "0.00 EV")
    #expect(strength.formatted(0.25) == "25%")
    #expect(contrast.formatted(1.1) == "1.10")
}

@Test func editableTextIsTheDisplayedNumberAtTheStepPrecision() {
    #expect(brightness.editableText(0.3) == "0.30")
    #expect(strength.editableText(0.25) == "25")
    #expect(contrast.editableText(1.1) == "1.10")
    let range = ParameterSpec(range: 0...3, step: 0.1, defaultValue: 2.5, format: .number(fractionDigits: 1))
    #expect(range.editableText(2.5) == "2.5")
}

@Test func typedValuesAreParsedLikeTheWeb() {
    #expect(brightness.parse("+0.30 EV") == 0.3)
    #expect(brightness.parse("0,3") == 0.3)
    #expect(brightness.parse("\u{2212}1") == -1)
    #expect(brightness.parse("\u{2013}0.5") == -0.5)
    #expect(brightness.parse(".5") == 0.5)
    #expect(brightness.parse("9") == 2)
    #expect(brightness.parse("") == nil)
    #expect(brightness.parse("auto") == nil)
    // Percentages are typed as displayed.
    #expect(strength.parse("25") == 0.25)
    #expect(strength.parse("25%") == 0.25)
    #expect(strength.parse("23") == 0.25)
}

@Test func originIsKeptInsideTheRange() {
    let spec = ParameterSpec(range: 1...2, step: 0.1, defaultValue: 1, origin: 0)
    #expect(spec.origin == 1)
    #expect(!spec.isCentred)
}

@Test func editableTextKeepsTheDigitsOfNonDecimalSteps() {
    let quarter = ParameterSpec(range: 0...2, step: 0.25, defaultValue: 1, format: .number(fractionDigits: 2))
    #expect(quarter.editableText(0.25) == "0.25")
    let eighth = ParameterSpec(range: 0...2, step: 0.125, defaultValue: 1, format: .number(fractionDigits: 3))
    #expect(eighth.editableText(0.125) == "0.125")
    #expect(quarter.parse(quarter.editableText(0.75)) == 0.75)
    let tenth = ParameterSpec(range: 0...3, step: 0.1, defaultValue: 1, format: .number(fractionDigits: 1))
    #expect(tenth.editableText(0.3) == "0.3")
    let whole = ParameterSpec(range: 0...10, step: 1, defaultValue: 1, format: .number(fractionDigits: 0))
    #expect(whole.editableText(4) == "4")
}
