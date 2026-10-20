import Foundation
import Testing
@testable import HyperDRRecipe

@Test func versionOneRoundTrip() throws {
    let recipe = Recipe()
    #expect(recipe.version == 1)
    #expect(try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe)) == recipe)
}

@Test func parameterDesignContract() throws {
    let exposure = ParameterDeclaration(id: "tone.exposure", group: .light,
        range: -4...4, step: 0.01, default: .constant(.number(0)), format: .ev, origin: .zero)
    #expect(exposure.labelKey == "ctrl.tone.exposure.label")
    #expect(exposure.helpKey == "ctrl.tone.exposure.help")
    #expect(exposure.undoKey == "undo.tone.exposure")
    #expect(try JSONDecoder().decode(ParameterDeclaration.self,
        from: JSONEncoder().encode(exposure)) == exposure)
}
