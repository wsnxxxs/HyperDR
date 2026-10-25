import CoreGraphics
import Foundation
import HyperDRDesign
import HyperDRRecipe
import Observation

/// The colour mixer's eyedropper (adjust-tools §6.3): press a colour of the
/// photo and drag up or down to move the chosen attribute of the zones that
/// colour belongs to, in step with how much of it each zone holds. A neutral
/// pixel belongs to none and moves nothing. Shared by the Mac and the iPad.
@MainActor @Observable final class MixerPickModel {
    let picker = TargetPicker()
    /// The attribute the mixer section shows, which the drag adjusts.
    private(set) var attribute = MixerAttribute.hue

    @ObservationIgnored private weak var editor: RecipeEditor?

    /// What the mixer section is given.
    var picking: MixerPicking {
        MixerPicking(isActive: picker.isActive, toggle: { [weak self] in self?.picker.toggle() },
                     setAttribute: { [weak self] in self?.attribute = $0 })
    }

    /// Recipe units (−100…100) per canvas point of drag: the whole range in 200 points.
    static let unitsPerPoint = 0.5

    func attach(_ editor: RecipeEditor) {
        self.editor = editor
        picker.begin = { [weak self] fraction in try await self?.begin(at: fraction) }
    }

    private func begin(at fraction: CGPoint) async throws -> TargetPicker.Drag? {
        guard let editor, let component = HSLComponent(rawValue: attribute.rawValue) else { return nil }
        let weights = try await editor.pickHSL(at: fraction).weights
        // A neutral colour has no zone: nothing to move, no undo step.
        guard weights.reduce(0, +) > 0.001 else { return TargetPicker.Drag(apply: { _ in }, finish: {}) }
        editor.editingHSL(component, true)
        var last: CGFloat = 0
        return TargetPicker.Drag(apply: { [weak editor] rise in
            // The editor adds each step to the zones, weighted by what the colour holds in each.
            editor?.adjustHSL(component, weights: weights, delta: Double(rise - last) * Self.unitsPerPoint)
            last = rise
        }, finish: { [weak editor] in editor?.editingHSL(component, false) })
    }
}
