import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// Where the controls go, by window size (p7-adjustments §5.2, §5.3), not by
/// device orientation or size class, so Split View and Stage Manager pick the
/// right form as the window changes:
///
/// - iPad, window ≥ 1000 pt wide: the system inspector on the right, with the
///   generated inspector controls in touch sizes.
/// - iPad, narrower: the canvas on top and the large dock under it.
/// - iPhone: the dock under the canvas, or standing on the right when the
///   window is wider than tall.
enum EditorLayout: Equatable {
    case inspector
    case dock(axis: Axis, large: Bool)

    static var inspectorMinimumWindowWidth: CGFloat { 1000 }

    static func layout(for size: CGSize, isPad: Bool) -> EditorLayout {
        if isPad { return size.width >= inspectorMinimumWindowWidth ? .inspector : .dock(axis: .horizontal, large: true) }
        return size.width > size.height ? .dock(axis: .vertical, large: false) : .dock(axis: .horizontal, large: false)
    }
}

/// The dock: the current pane's controls over the tabs. Under the canvas it
/// reads top to bottom; standing on the right in landscape the tabs take the
/// outer edge.
struct EditorDock<Frame: View>: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    @Binding var pane: EditorPane
    let frameOn: Bool
    var axis: Axis = .horizontal
    var large = false
    var onEditingChanged: (ParameterDeclaration, Bool) -> Void = { _, _ in }
    var onReset: ((AdjustmentReset) -> Void)?
    var onBypass: (AdjustmentGroupID, Bool) -> Void = { _, _ in }
    var onLUTLibrary: () -> Void = {}
    @ViewBuilder let frame: () -> Frame

    var body: some View {
        let groups = panel.groups(for: recipe)
        let tabs = EditorTabs(groups: groups, pane: $pane, frameOn: frameOn, axis: axis, large: large,
                              onBypass: onBypass)
        if axis == .horizontal {
            VStack(spacing: large ? Space.s4 : Space.s3) {
                // One height for every pane, so the photo above stays put.
                content(groups)
                    .frame(maxWidth: large ? 720 : .infinity)
                    .frame(minHeight: large ? 250 : 212, alignment: .bottom)
                tabs
            }
            .padding(.top, Space.s3)
            .padding(.bottom, Space.s2)
        } else {
            HStack(spacing: Space.s3) {
                content(groups)
                    .frame(width: 236)
                tabs
            }
            .padding(.vertical, Space.s3)
            .padding(.trailing, Space.s2)
        }
    }

    @ViewBuilder private func content(_ groups: [AdjustmentGroupState]) -> some View {
        switch pane {
        case .frame:
            frame()
        case .group(let group):
            if let state = groups.first(where: { $0.group == group }) ?? groups.first {
                AdjustmentControls(recipe: $recipe, panel: panel, state: state, axis: axis, large: large,
                                   onEditingChanged: onEditingChanged, onReset: onReset, onLUTLibrary: onLUTLibrary)
                    .id(state.group)
            }
        }
    }
}
