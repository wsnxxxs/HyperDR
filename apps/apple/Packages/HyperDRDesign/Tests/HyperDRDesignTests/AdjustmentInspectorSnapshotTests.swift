import AppKit
import HyperDRRecipe
import SwiftUI
import Testing
@testable import HyperDRDesign

/// Writes the real Mac adjustment inspector (a RAW photo with white balance
/// pulled to the ends, Auto rows and a hovered-looking resting state) in light
/// and dark to $HDR_SNAPSHOT_DIR, to check the value boxes read as inputs.
/// Skipped when the variable is not set.
@MainActor @Test func adjustmentInspectorSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return }
    let context = AdjustmentContext(
        sourceValues: ["develop.temperature": 5600, "develop.tint": 4, "develop.luminanceNR": 30,
                       "develop.sharpness": 40, "develop.chromaNR": 10, "develop.moire": 0],
        automaticValues: ["hdr.range": 2.4],
        capabilities: ["CIRAWFilter.isLuminanceNoiseReductionSupported", "CIRAWFilter.isLensCorrectionSupported"])
    var recipe = Recipe(inputDomain: .rawEDR)
    let panel = AdjustmentPanel(context: context)
    panel.set("develop.temperature", number: 50_000, in: &recipe)
    panel.set("develop.tint", number: 200, in: &recipe)
    panel.set("tone.exposure", number: 0.3, in: &recipe)
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
        let view = SnapshotInspector(recipe: recipe, panel: panel)
            .frame(width: Layout.inspectorWidth)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("adjustment-inspector-\(name).png"))
    }
}

private struct SnapshotInspector: View {
    @State var recipe: Recipe
    let panel: AdjustmentPanel

    init(recipe: Recipe, panel: AdjustmentPanel) {
        _recipe = State(initialValue: recipe)
        self.panel = panel
    }

    var body: some View {
        AdjustmentInspector(recipe: $recipe, panel: panel, only: [.hdr, .light, .color])
            .background(Color.hdr.surfacePanel)
    }
}
