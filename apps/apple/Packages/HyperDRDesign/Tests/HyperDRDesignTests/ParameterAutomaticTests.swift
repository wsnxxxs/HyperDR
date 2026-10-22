import Foundation
import Testing
@testable import HyperDRDesign

private let hdrRange = ParameterSpec(range: 0...4, step: 0.1, defaultValue: -1,
                                     format: .number(fractionDigits: 1), automatic: ParameterAutomatic())
private let plain = ParameterSpec(range: 0...4, step: 0.1, defaultValue: 2.5, format: .number(fractionDigits: 1))
private let english = Locale(identifier: "en")
private let chinese = Locale(identifier: "zh-Hans")

@Test func onlyAValueBelowTheRangeOfAnAutoParameterIsAuto() {
    #expect(hdrRange.isAutomatic(-1))
    #expect(!hdrRange.isAutomatic(0))
    #expect(!hdrRange.isAutomatic(2.5))
    #expect(!plain.isAutomatic(-1))
}

@Test func theAutoReadoutIsTheWordInTheLanguageAsked() {
    #expect(hdrRange.formatted(-1, locale: english) == "Auto")
    #expect(hdrRange.formatted(-1, locale: chinese) == "自动")
    #expect(hdrRange.formatted(2.8, locale: chinese) == "2.8")
    #expect(hdrRange.editableText(-1) == "")
    #expect(hdrRange.editableText(2.8) == "2.8")
}

@Test func anEmptyFieldOrTheWordAutoParsesAsAuto() {
    for text in ["", "  ", "auto", "Auto", "AUTO", "自动"] { #expect(hdrRange.parse(text) == -1, "\(text)") }
    #expect(hdrRange.parse("2.5") == 2.5)
    #expect(hdrRange.parse("9") == 4)
    // Without an Auto state nothing of this is special.
    #expect(plain.parse("") == nil)
    #expect(plain.parse("auto") == nil)
    #expect(plain.parse("2.5") == 2.5)
}

@Test func steppingFromAutoLandsOnTheResumeValueEitherWay() {
    #expect(hdrRange.resumeValue == 2)
    #expect(hdrRange.stepped(-1, by: 1) == 2)
    #expect(hdrRange.stepped(-1, by: -1) == 2)
    #expect(hdrRange.stepped(-1, by: 10) == 2)
    #expect(hdrRange.stepped(2, by: 1) == 2.1)
    let resuming = ParameterSpec(range: 0...0.75, step: 0.01, defaultValue: -1, format: .percent,
                                 automatic: ParameterAutomatic(value: -1, resume: 0.25))
    #expect(resuming.stepped(-1, by: 1) == 0.25)
}

@Test func snappingNeverProducesAuto() {
    #expect(hdrRange.snapped(-1) == 0)
    #expect(hdrRange.snapped(-0.04) == 0)
    #expect(hdrRange.value(atFraction: -3) == 0)
    #expect(hdrRange.fraction(of: -1) == 0)
}

@Test func theCatalogueSaysAutoInBothLanguages() {
    #expect(DesignStrings.string("design.slider.auto", locale: english) == "Auto")
    #expect(DesignStrings.string("design.slider.auto", locale: chinese) == "自动")
    #expect(DesignStrings.string("design.slider.auto", locale: Locale(identifier: "fr")) == "Auto")
    #expect(DesignStrings.isAutomaticWord("auto"))
    #expect(!DesignStrings.isAutomaticWord("manual"))
}
