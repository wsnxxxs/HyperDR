import HyperDRRecipe
import Testing
@testable import HyperDRDesign

@Test func lightShowsTheTonesThenClarityAndDehaze() {
    // controls-polish §6: the panel's order only; the declarations keep theirs.
    let ids = AdjustmentPanel().group(group: .light, in: Recipe(inputDomain: .rawEDR))?.controls.map(\.id)
        .filter { $0.hasPrefix("tone.") && !$0.contains("urve") && !$0.contains("parametric") } ?? []
    #expect(ids == ["tone.exposure", "tone.contrast", "tone.highlights", "tone.shadows", "tone.whites", "tone.blacks",
                    "tone.clarity", "tone.dehaze"])
    #expect(Adjustments.parameters(in: .light).map(\.id).firstIndex(of: "tone.dehaze") == 1)
    #expect(AdjustmentPanel.startsCluster("tone.clarity"))
    #expect(AdjustmentPanel.startsCluster("color.vibrance"), "vibrance and saturation after the white balance")
}
