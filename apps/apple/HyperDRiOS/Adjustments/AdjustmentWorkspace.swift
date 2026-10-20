import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// The canvas and the adjustment controls, laid out by window size
/// (p7-adjustments §5.2, §5.3), not by device orientation or size class, so
/// Split View and Stage Manager pick the right form as the window changes:
///
/// - iPad, window ≥ 1000 pt wide: the inspector as a 320 pt sidebar on the
///   right, with touch sizes.
/// - iPad, narrower: the canvas on top (at least 55 % of the height) and the
///   large bar under it.
/// - iPhone: the bar under the canvas, or on the right standing up when the
///   window is wider than tall.
struct AdjustmentWorkspace<Canvas: View>: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    /// Drag brackets, for the host's undo (one drag, one step).
    var onEditingChanged: (ParameterDeclaration, Bool) -> Void = { _, _ in }
    /// Group and full resets the host performs and names itself.
    var onReset: ((AdjustmentReset) -> Void)?
    @ViewBuilder let canvas: Canvas

    static var sidebarMinimumWidth: CGFloat { 1000 }
    static var sidebarWidth: CGFloat { 320 }

    enum Form: Equatable { case sidebar, bottomPanel, bottomBar, sideBar }

    static func form(for size: CGSize, isPad: Bool) -> Form {
        if isPad { return size.width >= sidebarMinimumWidth ? .sidebar : .bottomPanel }
        return size.width > size.height ? .sideBar : .bottomBar
    }

    var body: some View {
        GeometryReader { geometry in
            switch Self.form(for: geometry.size, isPad: UIDevice.current.userInterfaceIdiom == .pad) {
            case .sidebar:
                HStack(spacing: 0) {
                    canvas
                    ScrollView {
                        AdjustmentInspector(recipe: $recipe, panel: panel, style: .touch,
                                            onEditingChanged: onEditingChanged, onReset: onReset)
                            .padding(.vertical, Space.s2)
                    }
                    .frame(width: Self.sidebarWidth)
                    .background(Color.hdr.surfacePanel)
                }
            case .bottomPanel:
                VStack(spacing: 0) {
                    canvas.frame(minHeight: geometry.size.height * 0.55)
                    AdjustmentBar(recipe: $recipe, panel: panel, large: true,
                                  onEditingChanged: onEditingChanged, onReset: onReset)
                }
            case .bottomBar:
                VStack(spacing: 0) {
                    canvas
                    AdjustmentBar(recipe: $recipe, panel: panel, onEditingChanged: onEditingChanged, onReset: onReset)
                }
            case .sideBar:
                HStack(spacing: 0) {
                    canvas
                    AdjustmentBar(recipe: $recipe, panel: panel, axis: .vertical,
                                  onEditingChanged: onEditingChanged, onReset: onReset)
                }
            }
        }
    }
}
