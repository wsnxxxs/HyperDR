import HyperDRDesign
import HyperDRRecipe
import HyperDRRender
import SwiftUI

/// How the canvas shows the photo (p7-adjustments §5.4).
enum Comparison: Hashable, CaseIterable { case edited, original, split }

/// The live EDR canvas with what goes over it: the split divider, the mask
/// legend, the status capsules and the headroom readout. With `framed` the
/// photo sits on its frame: the mat and caption are SDR views around the
/// canvas, so on an HDR display they stay at reference white while the photo
/// keeps its highlights, which is what the export looks like.
///
/// The canvas keeps its place in the view tree whether framed or not, so its
/// Metal layer and zoom survive the switch.
struct EditorCanvas: View {
    let session: EditingSession
    let editor: RecipeEditor
    let comparison: Comparison
    @Binding var splitRatio: Double
    @Binding var transform: CanvasTransform?
    /// Show the export's frame around the photo.
    let framed: Bool
    /// The margin around a framed card.
    var framePadding: CGFloat = Space.s5

    /// The canvas is held to show the original.
    @Binding var holdingOriginal: Bool
    @State private var headroom = HeadroomSnapshot()

    var body: some View {
        GeometryReader { proxy in
            let layout = framed ? session.frameLayout : nil
            let placement = Placement(layout: layout, in: proxy.size, padding: framed ? framePadding : 0)
            ZStack(alignment: .topLeading) {
                if let layout, session.frame.isEnabled {
                    mat(layout, placement: placement)
                }
                canvas
                    .frame(width: placement.print.width, height: placement.print.height)
                    .position(x: placement.print.midX, y: placement.print.midY)
                if let layout, session.frame.isEnabled, layout.caption.height > 0 {
                    FrameCaptionView(caption: session.caption(for: layout), settings: session.frame, layout: layout,
                                     scale: placement.scale)
                        .frame(width: placement.card.width, height: CGFloat(layout.caption.height) * placement.scale)
                        .position(x: placement.card.midX,
                                  y: placement.card.minY + (CGFloat(layout.caption.y) + CGFloat(layout.caption.height) / 2) * placement.scale)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.smooth(duration: 0.35), value: placement)
        }
        .overlay(alignment: .top) { status.padding(.top, Space.s2) }
        .overlay(alignment: .bottomLeading) { headroomBadge }
    }

    // MARK: Frame

    /// Where the card and the photo go in the space offered.
    struct Placement: Equatable {
        var card: CGRect
        var print: CGRect
        /// Points per engine pixel; 0 when not framed.
        var scale: CGFloat

        init(layout: FramePixelLayout?, in size: CGSize, padding: CGFloat) {
            guard let layout, layout.width > 0, layout.height > 0 else {
                card = CGRect(origin: .zero, size: size)
                print = card
                scale = 0
                return
            }
            let room = CGSize(width: max(1, size.width - 2 * padding), height: max(1, size.height - 2 * padding))
            let scale = min(room.width / CGFloat(layout.width), room.height / CGFloat(layout.height))
            let card = CGRect(x: (size.width - CGFloat(layout.width) * scale) / 2,
                              y: (size.height - CGFloat(layout.height) * scale) / 2,
                              width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale)
            self.card = card
            self.scale = scale
            print = CGRect(x: card.minX + CGFloat(layout.photo.x) * scale, y: card.minY + CGFloat(layout.photo.y) * scale,
                           width: CGFloat(layout.photo.width) * scale, height: CGFloat(layout.photo.height) * scale)
        }
    }

    /// The paper, and the print's shadow on it (sigma as the shadow radius).
    private func mat(_ layout: FramePixelLayout, placement: Placement) -> some View {
        let reference = CGFloat(layout.referenceEdge) * placement.scale
        let shadow = session.frame.showsShadow ? session.frame.style.geometry.shadow : nil
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(session.frame.tone.background.color)
                .frame(width: placement.card.width, height: placement.card.height)
                .position(x: placement.card.midX, y: placement.card.midY)
            Rectangle()
                .fill(Color.hdr.previewBackdrop)
                .shadow(color: .black.opacity(shadow?.opacity ?? 0), radius: (shadow?.blur ?? 0) * reference,
                        y: (shadow?.offset ?? 0) * reference)
                .frame(width: placement.print.width, height: placement.print.height)
                .position(x: placement.print.midX, y: placement.print.midY)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: Canvas

    private var canvas: some View {
        EDRCanvas(content: content,
                  fitRequest: framed,
                  onHeadroom: { headroom = $0 },
                  onDrawableSize: { editor.canvasPixelSize = $0 },
                  onHoldOriginal: { holdingOriginal = $0 },
                  onError: { _ in session.notice = "ios.error.load" },
                  onTransform: { transform = $0 })
            .overlay { adornments }
    }

    /// The original of the shown photo, when there is one to compare with.
    private var original: EditorFrame? {
        editor.originalFrame.flatMap { $0.request.sourceID == editor.frame?.request.sourceID ? $0 : nil }
    }

    var mode: DisplayComposition.Mode { Self.mode(editor, comparison: comparison, holding: holdingOriginal) }

    static func mode(_ editor: RecipeEditor, comparison: Comparison, holding: Bool) -> DisplayComposition.Mode {
        let original = editor.originalFrame.flatMap { $0.request.sourceID == editor.frame?.request.sourceID ? $0 : nil }
        guard original != nil else { return .edited }
        if holding { return .original }
        switch comparison {
        case .original: return .original
        case .edited: return .edited
        case .split: return .compare
        }
    }

    private var content: EDRCanvasUIView.Content? {
        guard let frame = editor.frame, let source = editor.frameSource else { return nil }
        // Until the new photo's first frame arrives the previous one stays, at its own size.
        let size = source.pixelSize
        let original = original
        let originalDetail = original == nil ? nil : editor.shownOriginalDetail
        return EDRCanvasUIView.Content(edited: DisplayPair(frame.display),
                                       original: original.map { DisplayPair($0.display) },
                                       editedDetail: editor.shownDetail.map { DisplayPair($0.display) },
                                       originalDetail: originalDetail.map { DisplayPair($0.display) },
                                       mode: mode, splitRatio: splitRatio,
                                       mask: editor.shownMask.map { DisplayMask($0.mask) },
                                       previewsAsSDR: editor.previewsAsSDR,
                                       imageSize: CGSize(width: size.width, height: size.height))
    }

    /// The split divider and the mask legend, in the canvas's coordinates.
    @ViewBuilder private var adornments: some View {
        if let transform, transform.imageFrame.width > 0 {
            let image = transform.imageFrame
            let visible = image.intersection(CGRect(origin: .zero, size: transform.viewport))
            ZStack {
                if mode == .compare {
                    SplitOverlay(ratio: splitRatio, imageFrame: image,
                                 visibleRect: CGRect(origin: .zero, size: transform.viewport),
                                 originalLabel: Text("ios.view.original"), editedLabel: Text("ios.view.edited"),
                                 showsHDRBadge: false, hitWidth: SplitGeometry.touchHitWidth,
                                 onDrag: { splitRatio = $0 },
                                 onNudge: { splitRatio = min(max(splitRatio + $0, SplitGeometry.ratioRange.lowerBound),
                                                             SplitGeometry.ratioRange.upperBound) })
                }
                if let mask = editor.shownMask, mode != .original, !visible.isNull,
                   let declaration = Adjustments.declaration(mask.parameterID) {
                    CanvasLegend(rows: [.mask(controlName: AdjustmentText.label(declaration))])
                        .padding(Space.s3)
                        .frame(width: visible.width, height: visible.height,
                               alignment: mode == .compare ? .bottomTrailing : .bottomLeading)
                        .position(x: visible.midX, y: visible.midY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: Status

    private var status: some View {
        VStack(spacing: Space.s2) {
            if holdingOriginal, editor.originalFrame != nil { capsule(Text("ios.canvas.original")) }
            if editor.aiStatus == .computing { capsule(Text("ios.ai.computing"), progress: true) }
            if case .failed = editor.aiStatus { capsule(Text("ios.ai.failed")) }
            if editor.sourceChanged { capsule(Text("ios.error.sourceChanged")) }
            if let notice = session.notice { capsule(Text(notice)) }
            if session.loading, editor.frame != nil { capsule(Text("ios.canvas.opening"), progress: true) }
        }
        .animation(.smooth(duration: 0.25), value: holdingOriginal)
        .animation(.smooth(duration: 0.25), value: session.loading)
        .task(id: session.notice) {
            guard session.notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { session.notice = nil }
        }
        .allowsHitTesting(false)
    }

    private func capsule(_ text: Text, progress: Bool = false) -> some View {
        HStack(spacing: Space.s2) {
            if progress { ProgressView().controlSize(.mini) }
            text
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// The display's headroom now and at most, when it has any.
    @ViewBuilder private var headroomBadge: some View {
        if headroom.potential > 1.01, !framed {
            HStack(spacing: 4) {
                Text(verbatim: "HDR").font(.caption2.weight(.bold))
                Text(verbatim: Self.headroom(headroom.current)).font(.caption2.monospacedDigit())
            }
            .foregroundStyle(Color.hdr.amber.opacity(0.9))
            .padding(.horizontal, Space.s2)
            .padding(.vertical, 3)
            .background(.black.opacity(0.35), in: .capsule)
            .padding(Space.s3)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("ios.display.edr \(Self.headroom(headroom.current)) \(Self.headroom(headroom.potential))"))
        }
    }

    static func headroom(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(1))) + "×"
    }
}
