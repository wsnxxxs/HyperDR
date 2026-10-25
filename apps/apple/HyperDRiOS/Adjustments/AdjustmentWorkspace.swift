import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// Where the dock goes (p7-adjustments §5.3): under the canvas, or on the
/// iPhone standing on the right when the window is wider than tall. In an
/// iPad window as narrow as an iPhone the dock is the large one, under the
/// canvas; a wider iPad window has the Studio (`PadLayout`).
struct EditorLayout: Equatable {
    let axis: Axis
    let large: Bool

    static func layout(for size: CGSize, isPad: Bool) -> EditorLayout {
        if isPad { return EditorLayout(axis: .horizontal, large: true) }
        return EditorLayout(axis: size.width > size.height ? .vertical : .horizontal, large: false)
    }
}

/// The dock: the current pane's controls over the tabs. Under the canvas it
/// reads top to bottom; standing on the right in landscape the tabs take the
/// outer edge.
struct EditorDock<Frame: View>: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    @Binding var pane: EditorPane
    /// The section page open over the Adjust tab (controls-polish §8), nil for the rings.
    @Binding var section: AdjustmentSections.Kind?
    let frameOn: Bool
    /// The photo's own size, for the crop pane's ratios; nil before a photo.
    var photo: GeometrySize? = nil
    var axis: Axis = .horizontal
    var large = false
    var onEditingChanged: (ParameterDeclaration, Bool) -> Void = { _, _ in }
    var onReset: ((AdjustmentReset) -> Void)?
    var onBypass: (AdjustmentGroupID, Bool) -> Void = { _, _ in }
    /// The crop pane's drags begin and end.
    var onGeometryEditing: (Bool) -> Void = { _ in }
    /// The crop pane's Auto; nil hides it.
    var upright: GeometryUpright?
    var onLUTLibrary: () -> Void = {}
    /// Why AI cannot be chosen, when it cannot (beside the HDR source).
    var aiUnavailable: Text?
    @ViewBuilder let frame: () -> Frame

    var body: some View {
        let groups = DockGroup.tabs(panel.groups(for: recipe))
        // Any tab, the current one too, leaves a section's page.
        let pane = Binding(get: { self.pane }, set: { next in
            withAnimation(.smooth(duration: 0.3)) {
                section = nil
                self.pane = next
            }
        })
        let tabs = EditorTabs(groups: groups, pane: pane, cropOn: !recipe.geometry.isIdentity, frameOn: frameOn,
                              axis: axis, large: large, onBypass: onBypass)
        if axis == .horizontal {
            VStack(spacing: large ? Space.s4 : Space.s3) {
                // One height for every pane, so the photo above stays put.
                // A section's page raises the dock; the photo above shrinks but stays whole.
                content(groups)
                    .frame(maxWidth: large ? 720 : .infinity)
                    .frame(minHeight: section != nil ? (large ? 420 : 372) : (large ? 250 : 212),
                           maxHeight: section != nil ? (large ? 420 : 372) : nil, alignment: .bottom)
                tabs
            }
            .padding(.top, Space.s3)
            .padding(.bottom, Space.s2)
        } else {
            HStack(spacing: Space.s3) {
                content(groups)
                    .frame(width: section != nil ? 340 : 236)
                tabs
            }
            .padding(.vertical, Space.s3)
            .padding(.trailing, Space.s2)
        }
    }

    @ViewBuilder private func content(_ groups: [DockGroup]) -> some View {
        switch pane {
        case .frame:
            frame()
        case .crop:
            CropControls(recipe: $recipe, photo: photo, axis: axis, large: large, upright: upright,
                         onEditing: onGeometryEditing)
        case .group(let group):
            if let section, let tab = groups.first(where: { $0.contains(group) }), tab.isMerged || tab.id != .look {
                DockSectionPane(recipe: $recipe, panel: panel, kind: section, axis: axis,
                                onEditingChanged: onEditingChanged) {
                    withAnimation(.smooth(duration: 0.3)) { self.section = nil }
                }
                .transition(.opacity)
            } else if let tab = groups.first(where: { $0.contains(group) }) ?? groups.first {
                AdjustmentControls(recipe: $recipe, panel: panel, group: tab, axis: axis, large: large,
                                   onEditingChanged: onEditingChanged, onReset: onReset, onLUTLibrary: onLUTLibrary,
                                   aiUnavailable: aiUnavailable,
                                   onOpenSection: { kind in withAnimation(.smooth(duration: 0.3)) { section = kind } })
                    .id(tab.id)
            }
        }
    }
}
