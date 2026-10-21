import SwiftUI
import HyperDRRecipe
import HyperDRDesign

/// What is drawn over the photograph besides the badge: the compare divider
/// with its two labels, the "Original · release to return" label while the
/// original is held, the legend that explains the overlay colours, and the
/// hint at the foot. All of it is aligned to `canvas.imageFrame` and to the
/// part of the photo that can be seen, so it stays on screen when zoomed in.
///
/// Only the divider takes the pointer; the rest lets it through to the canvas.
struct CanvasAdornments: View {
    let model: EditorModel
    let hint: CanvasHintState
    let showsInspector: Bool
    /// How much of the canvas's foot is taken by the card, chip and capsule
    /// (`CanvasBottomReserve.total`): the legend and the hint stay above it.
    var bottomReserve: CGFloat = 0
    /// The divider was grabbed or let go; the user is acting on the canvas.
    var onSplitEditing: (Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            if let image = model.canvas.imageFrame {
                let visible = image.intersection(CGRect(origin: .zero, size: proxy.size))
                if !visible.isNull, visible.width > 0, visible.height > 0 {
                    adornments(image: image, visible: visible, canvas: proxy.size)
                }
            }
        }
    }

    // MARK: Layout

    @ViewBuilder private func adornments(image: CGRect, visible: CGRect, canvas: CGSize) -> some View {
        let canvasWidth = canvas.width
        let clearance = CanvasBottomReserve.clearance(reserve: bottomReserve, canvasHeight: canvas.height, visibleMaxY: visible.maxY)
        let peeking = model.isPeekingOriginal
        let comparing = Self.showsSplit(viewMode: model.viewMode, isPeeking: peeking,
                                        hasReference: model.hasReferenceFrame, hasEdited: model.hasEditedFrame)
        let legend = Self.legendRows(model: model, showsInspector: showsInspector)
        ZStack {
            if comparing {
                SplitOverlay(ratio: model.splitRatio, imageFrame: image, visibleRect: visible,
                             originalLabel: Text("editor.original"), editedLabel: Text("editor.effect"),
                             showsHDRBadge: model.showsHDRBadge,
                             onDrag: { model.setSplitRatio($0) }, onEditingChanged: onSplitEditing,
                             onNudge: { model.nudgeSplit(by: $0) })
            }
            if peeking {
                Label("canvas.peeking", systemImage: "eye")
                    .font(Font.hdr.caption)
                    .hdrOverlayChip()
                    .padding(.top, 12)
                    .frame(width: visible.width, height: visible.height, alignment: .top)
                    .position(x: visible.midX, y: visible.midY)
                    .allowsHitTesting(false)
            }
            if !legend.isEmpty {
                let dividerX = comparing ? SplitGeometry.dividerX(ratio: model.splitRatio, in: image) : visible.minX  // legend sits right of the divider
                CanvasLegend(rows: legend)
                    .reportsCanvasFrame(name: "legend")
                    .padding(.leading, 12 + max(0, dividerX - visible.minX))
                    .padding(.bottom, 12 + clearance)
                    .frame(width: visible.width, height: visible.height, alignment: .bottomLeading)
                    .position(x: visible.midX, y: visible.midY)
                    .allowsHitTesting(false)
            }
            if let key = hint.shown, legend.isEmpty {
                CanvasHint(Text(LocalizedStringKey(key)))
                    .frame(maxWidth: max(0, canvasWidth - 32))
                    .reportsCanvasFrame(name: "hint")
                    .padding(.bottom, 16 + clearance)
                    .frame(width: visible.width, height: visible.height, alignment: .bottom)
                    .position(x: visible.midX, y: visible.midY)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .hdrAnimation(Motion.slow, value: hint.shown)
    }

    // MARK: Rules

    /// The legend now, for the model's state: what `adornments` draws, and
    /// what the hint gives way to.
    static func legendRows(model: EditorModel, showsInspector: Bool) -> [CanvasLegendRow] {
        legendRows(highlightZebra: model.showsHighlightZebra, shadowZebra: model.showsShadowZebra,
                   showsInspector: showsInspector, viewMode: model.viewMode, isPeeking: model.isPeekingOriginal)
    }

    /// The divider shows in compare mode when both renditions exist and the
    /// original is not being held (that shows the original whole).
    static func showsSplit(viewMode: ViewMode, isPeeking: Bool, hasReference: Bool, hasEdited: Bool) -> Bool {
        viewMode == .compare && !isPeeking && hasReference && hasEdited
    }

    /// The legend's rows: the zebras only while the inspector, whose
    /// switches already say it, is hidden. Nothing over the original, or
    /// while it is held.
    static func legendRows(highlightZebra: Bool, shadowZebra: Bool, showsInspector: Bool,
                           viewMode: ViewMode, isPeeking: Bool) -> [CanvasLegendRow] {
        guard viewMode != .original, !isPeeking else { return [] }
        var rows: [CanvasLegendRow] = []
        if !showsInspector {
            if highlightZebra { rows.append(.highlightZebra) }
            if shadowZebra { rows.append(.shadowZebra) }
        }
        return rows
    }
}
