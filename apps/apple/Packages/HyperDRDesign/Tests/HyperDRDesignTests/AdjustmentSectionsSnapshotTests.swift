import AppKit
import HyperDRRecipe
import SwiftUI
import Testing
@testable import HyperDRDesign

/// Writes the Light and Adjust groups of the real inspector with the curve,
/// the mixer and the grading open and edited, in light and dark, to
/// $HDR_SNAPSHOT_DIR (controls-polish: the before/after record). Skipped when
/// the variable is not set.
@MainActor @Test func adjustmentSectionsSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return }
    let panel = AdjustmentPanel(context: AdjustmentContext(automaticValues: ["hdr.range": 3]))
    var recipe = Recipe(inputDomain: .rawEDR)
    panel.set("tone.curve", curve: [0, 0, 0.25, 0.2, 0.6, 0.68, 1, 1, 2.5, 2.9], in: &recipe)
    panel.set("tone.clarity", number: 15, in: &recipe)
    for (id, value) in [("hsl.red.hue", -20.0), ("hsl.green.hue", 12), ("grade.shadows.hue", 250), ("grade.shadows.saturation", 55),
                        ("grade.highlights.hue", 70), ("grade.highlights.saturation", 30), ("grade.midtones.luminance", -10)] {
        panel.set(id, number: value, in: &recipe)
    }
    let picking = CurvePicking(isActive: false, inputs: ["tone.curve": 0.45], toggle: {})
    let mixer = MixerPicking(isActive: false, toggle: {}, setAttribute: { _ in })
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
        let view = SectionsHost(recipe: recipe, panel: panel)
            .environment(\.curvePicking, picking)
            .environment(\.mixerPicking, mixer)
        let bitmap = try snapshot(view, width: Layout.inspectorWidth, scheme: scheme)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sections-mac-\(name).png"))
    }
}

private struct SectionsHost: View {
    @State var recipe: Recipe
    let panel: AdjustmentPanel

    var body: some View {
        AdjustmentInspector(recipe: $recipe, panel: panel, only: [.light, .color])
            .background(Color.hdr.surfacePanel)
    }
}

/// The clipping legend on a photo-like grey, to $HDR_SNAPSHOT_DIR.
@MainActor @Test func clippingLegendSnapshot() throws {
    guard let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return }
    let view = ClippingLegend().padding(Space.s3).background(Color(white: 0.55))
    let bitmap = try snapshot(view, width: 220, scheme: .light)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("clipping-legend.png"))
}
