import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRDesign

private let english = Locale(identifier: "en")
private let chinese = Locale(identifier: "zh-Hans")

private func panel(automatic: Double? = 0.59) -> AdjustmentPanel {
    AdjustmentPanel(context: AdjustmentContext(automaticValues: automatic.map { ["look.filmExposure": $0] } ?? [:]))
}

@MainActor @Test func noFilmMeansNoNote() {
    #expect(FilmExposureNote.text(recipe: Recipe(inputDomain: .rawEDR), panel: panel(), locale: english) == nil)
}

@MainActor @Test func anAutomaticFilmExposureIsNamedWithItsValue() {
    var recipe = Recipe(inputDomain: .rawEDR)
    panel().set("look.film", option: "portra400", in: &recipe)
    #expect(FilmExposureNote.text(recipe: recipe, panel: panel(), locale: english)
            == "Film auto exposure +0.59 · adjust in Style")
    #expect(FilmExposureNote.text(recipe: recipe, panel: panel(), locale: chinese)
            == "胶片自动曝光 +0.59 · 在风格中调整")
    #expect(FilmExposureNote.text(recipe: recipe, panel: panel(automatic: nil), locale: english)
            == "Film auto exposure · adjust in Style")
}

@MainActor @Test func aManualFilmExposureShowsTheManualValue() {
    var recipe = Recipe(inputDomain: .rawEDR)
    let panel = panel()
    panel.set("look.film", option: "portra400", in: &recipe)
    panel.set("look.filmExposure", number: -0.3, in: &recipe)
    #expect(FilmExposureNote.text(recipe: recipe, panel: panel, locale: english) == "Film exposure -0.30 · adjust in Style")
}

@MainActor @Test func filmExposureStandsRightUnderTheStockTiles() {
    var recipe = Recipe(inputDomain: .rawEDR)
    let panel = panel()
    panel.set("look.film", option: "portra400", in: &recipe)
    let ids = panel.group(group: .look, in: recipe)?.controls.map(\.id) ?? []
    let film = ids.firstIndex(of: "look.film")!
    #expect(ids[film + 1] == "look.filmExposure")
    #expect(ids[film + 2] == "look.filmStrength")
}

@Test func revealingTheFilmExposureBringsTheBuiltInTabForward() {
    #expect(LookSection.kind(revealing: "look.filmExposure", current: .imported) == .builtIn)
    #expect(LookSection.kind(revealing: "look.filmStrength", current: .imported) == .builtIn)
    #expect(LookSection.kind(revealing: "look.strength", current: .imported) == .imported)
    #expect(LookSection.kind(revealing: "tone.exposure", current: .imported) == .imported)
    #expect(LookSection.kind(revealing: nil, current: .imported) == .imported)
}
