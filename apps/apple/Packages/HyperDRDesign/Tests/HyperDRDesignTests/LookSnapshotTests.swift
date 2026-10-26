import AppKit
import HyperDRRecipe
import SwiftUI
import Testing
@testable import HyperDRDesign

/// Writes the look group with a Log LUT on (its exposure on Auto, its spaces)
/// in light and dark to $HDR_SNAPSHOT_DIR (controls-polish §7). Skipped when
/// the variable is not set.
@MainActor @Test func lookSpacesSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return }
    let lut = LUTReference(contentHash: "sha256:00aa", name: "S-Log3 to Rec.709")
    let panel = AdjustmentPanel(context: AdjustmentContext(automaticValues: ["look.exposure": 1.42], luts: [lut]))
    var recipe = Recipe(inputDomain: .rawEDR)
    panel.set("look.lut", reference: lut.contentHash, in: &recipe)
    panel.set("look.input", option: "slog3-sgamut3cine", in: &recipe)
    panel.set("look.output", option: "rec709", in: &recipe)
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
        let bitmap = try snapshot(LookHost(recipe: recipe, panel: panel), width: Layout.inspectorWidth, scheme: scheme)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("look-mac-\(name).png"))
    }
    let unavailable = AdjustmentPanel(context: AdjustmentContext(luts: [lut], lookSpaces: [
        lut.contentHash: AdjustmentLookSpaces(input: "slog3-sgamut3cine", output: "rec709")
    ]))
    let control = try #require(unavailable.control(Recipe.lookID, in: Recipe(inputDomain: .sdr)))
    for language in ["en", "zh-Hans"] {
        let picker = LookPicker(control: control, panel: unavailable, style: .pointer,
            selection: .constant(""), onLibrary: {})
            .padding(12).environment(\.locale, Locale(identifier: language))
            .background(Color.hdr.surfacePanel)
        let bitmap = try snapshot(picker, width: 300)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("look-unavailable-\(language).png"))
    }
}

private struct LookHost: View {
    @State var recipe: Recipe
    let panel: AdjustmentPanel

    var body: some View {
        AdjustmentInspector(recipe: $recipe, panel: panel, only: [.look])
            .background(Color.hdr.surfacePanel)
    }
}
