import CoreGraphics
import Foundation
import HyperDRDesign
import HyperDRRecipe
import Observation

/// The curve eyedropper (adjust-tools §2.2): the picker of a drag on the
/// photo, aimed at the curve the curve section shows. Shared by the Mac and
/// the iPad; each host supplies the canvas point to photo point mapping.
@MainActor @Observable final class CurvePickModel {
    let picker = TargetPicker()
    /// The curve the drag edits, as the section last said.
    private(set) var parameterID = "tone.curve"

    @ObservationIgnored private weak var editor: RecipeEditor?
    @ObservationIgnored private let panel = AdjustmentPanel()

    /// What the curve section is given.
    var picking: CurvePicking {
        CurvePicking(isActive: picker.isActive, inputs: picker.marks,
                     toggle: { [weak self] in self?.picker.toggle() },
                     select: { [weak self] in self?.parameterID = $0 })
    }

    func attach(_ editor: RecipeEditor) {
        self.editor = editor
        picker.begin = { [weak self] fraction in try await self?.begin(at: fraction) }
    }

    /// Curves with a segment above SDR white.
    private static let hdrCurves: Set<String> = ["tone.curve", "tone.curveHDR"]

    private func begin(at fraction: CGPoint) async throws -> TargetPicker.Drag? {
        guard let editor else { return nil }
        let id = parameterID
        guard let declaration = Adjustments.declaration(id) else { return nil }
        let sample = try await editor.pickCurve(at: fraction, parameterID: id)
        var coordinates = ToneCurve().coordinates
        if case .curve(let values)? = panel.control(id, in: editor.recipe)?.value { coordinates = values }
        let edit = CurveTargetedEdit(coordinates: coordinates, input: sample.coordinate,
                                     maxValue: Self.hdrCurves.contains(id) ? 5 : 1, liftsOnly: id == "tone.curveHDR")
        let marks = [id: sample.coordinate]
        guard edit.canEdit else { return TargetPicker.Drag(apply: { _ in }, finish: {}, marks: marks) }
        editor.editingChanged(declaration, true)
        return TargetPicker.Drag(apply: { [weak editor, panel] rise in
            guard let editor else { return }
            var recipe = editor.recipe
            panel.set(id, curve: edit.coordinates(raisedByDrag: Double(rise)), in: &recipe)
            editor.setRecipe(recipe)
        }, finish: { [weak editor] in editor?.editingChanged(declaration, false) }, marks: marks)
    }
}
