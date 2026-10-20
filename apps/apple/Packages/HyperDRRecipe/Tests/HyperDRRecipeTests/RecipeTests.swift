import Foundation
import Testing
@testable import HyperDRRecipe

@Test func versionOneRoundTrip() throws {
    let recipe = Recipe()
    #expect(recipe.version == 1)
    #expect(try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe)) == recipe)
}
