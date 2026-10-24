import Foundation
import HyperDRRecipe

/// What one undo step did, which names it (p7-2b §4).
nonisolated enum RecipeEdit: Equatable, Sendable {
    /// One control: a drag, a typed value, a switch, a choice, its own reset.
    case parameter(String)
    /// ↺ on a group.
    case resetGroup(ParameterGroup)
    /// Reset All.
    case resetAll
    /// The crop pane: crop, straightening, perspective, turns, mirror.
    case geometry

    /// The catalogue key of the action name; `%@` in `undo.resetGroup %@` is
    /// the group's name. The words live in HyperDRDesign's catalogue
    /// (`AdjustmentText.undoName`), shared by the three platforms.
    var undoKey: String {
        switch self {
        case .parameter(let id): return Adjustments.declaration(id)?.undoKey ?? "undo.\(id)"
        case .resetGroup: return "undo.resetGroup %@"
        case .resetAll: return "undo.resetAll"
        case .geometry: return "undo.geometry"
        }
    }

    /// What a write of `after` over `before` did, for writes that do not say
    /// (the controls write the recipe through a binding). A reset of a group
    /// is recognised when it changed two or more controls, Reset All when it
    /// changed controls in two or more groups; otherwise the write is named
    /// after what it chose (a film, a LUT, a source: a choice or reference it
    /// changed, ahead of the numbers it brought along, such as a stock's grain
    /// and halation), else the first control it changed, which is also what
    /// that control's own reset is called. Hosts that know what they reset say so through
    /// `RecipeEditor.resetGroup` and `resetAll`, which are always exact.
    static func classify(from before: Recipe, to after: Recipe) -> RecipeEdit? {
        let changed = Adjustments.all.filter { before.value(for: $0.id) != after.value(for: $0.id) }
        guard let first = changed.first else { return before.geometry != after.geometry ? .geometry : nil }
        if changed.count >= 2 {
            let groups = Set(changed.map(\.group))
            if groups.count == 1, let group = groups.first {
                if after == before.resetting(group) { return .resetGroup(group) }
            } else if after == before.resettingAll() {
                return .resetAll
            }
        }
        return .parameter((changed.first { $0.kind == .choice || $0.kind == .reference } ?? first).id)
    }
}

/// One step: the recipe before and after, and its name.
nonisolated struct RecipeStep: Equatable, Sendable {
    let before: Recipe
    let after: Recipe
    let edit: RecipeEdit
}

extension Recipe {
    /// Every parameter of a group back to its declared default, hidden ones
    /// included (the same rule as `AdjustmentPanel.reset(group:)`).
    nonisolated func resetting(_ group: ParameterGroup) -> Recipe {
        var recipe = self
        for declaration in Adjustments.parameters(in: group) {
            if declaration.id == Recipe.lookID { recipe.look = nil } else { recipe.setValue(nil, for: declaration.id) }
        }
        return recipe
    }

    /// Every declared parameter back to its default, and the crop with them;
    /// values for ids this build does not know are left alone.
    nonisolated func resettingAll() -> Recipe {
        var recipe = ParameterGroup.displayOrder.reduce(self) { $0.resetting($1) }
        recipe.geometry = .identity
        return recipe
    }
}

/// Registers recipe steps with the host's `UndoManager`: the Mac window's, the
/// iOS scene's (p7-2b §4). Undo sets the recipe back to `before` and registers
/// the redo; redo does the reverse. Nothing else (view state, bypassed groups,
/// export settings, frames) goes through here.
@MainActor final class RecipeUndo {
    private(set) weak var undoManager: UndoManager?
    /// Turns an edit into the menu's "Undo Change Exposure". The default is the
    /// catalogue key, which tests read.
    var actionName: @MainActor (RecipeEdit) -> String = { $0.undoKey }

    /// Called with the recipe to show after an undo or redo.
    private let restore: @MainActor (Recipe) -> Void

    init(restore: @escaping @MainActor (Recipe) -> Void) {
        self.restore = restore
    }

    /// Moves to another undo manager; steps registered with the previous one are removed.
    func attach(_ manager: UndoManager?) {
        guard manager !== undoManager else { return }
        undoManager?.removeAllActions(withTarget: self)
        undoManager = manager
    }

    func register(_ step: RecipeStep) {
        guard step.before != step.after, let undoManager else { return }
        register(restoring: step.before, then: step.after, edit: step.edit, on: undoManager)
    }

    private func register(restoring recipe: Recipe, then other: Recipe, edit: RecipeEdit, on manager: UndoManager) {
        // A manager that does not group by event (the Mac editor's own, which
        // keeps steps apart from AppKit text) needs each step in a group of
        // its own; inside an undo or redo the manager has one open already.
        let grouped = !manager.groupsByEvent && manager.groupingLevel == 0
        if grouped { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { undo in
            MainActor.assumeIsolated {
                undo.restore(recipe)
                undo.register(restoring: other, then: recipe, edit: edit, on: manager)
            }
        }
        manager.setActionName(actionName(edit))
        if grouped { manager.endUndoGrouping() }
        didRegister?()
    }

    /// Makes the next registration a step of its own even inside the current
    /// event's undo group (UIKit and AppKit group everything registered in
    /// one event, so a drag committed by a tap and the tap's own edit would
    /// otherwise undo together). Only a single open group, the event's, is
    /// split; nested groups a host opened are left alone.
    func separateNextStep() {
        guard let undoManager, undoManager.groupingLevel == 1 else { return }
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
    }

    /// Called after every registration (the Mac refreshes its Undo menu items).
    var didRegister: (@MainActor () -> Void)?

    /// A different photo: its edits are not this photo's.
    func clear() {
        undoManager?.removeAllActions(withTarget: self)
    }
}
