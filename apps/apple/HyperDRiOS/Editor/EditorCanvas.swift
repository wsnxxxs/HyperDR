import HyperDRDesign
import HyperDRRecipe
import HyperDRRender
import SwiftUI

/// How the canvas shows the photo (p7-adjustments §5.4).
enum Comparison: Hashable, CaseIterable { case edited, original, split }

/// The live EDR canvas with what goes over it: the split divider, the
/// status capsules, and at the photo's top right the badge the
/// Mac canvas carries (HDR on the edited photo, Original on the original). With `framed` the
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
    /// The crop pane: the whole photo through its geometry, with the crop box over it.
    var cropping = false
    /// The margin around a framed card.
    var framePadding: CGFloat = Space.s5

    /// The canvas is held to show the original.
    @Binding var holdingOriginal: Bool
    /// The white balance eyedropper, where the host offers one (the iPad's
    /// Studio): while it is active a layer over the photo takes the touch.
    var whiteBalance: WhiteBalancePicker? = nil
    /// The curve and colour mixer eyedroppers, where the host offers them: a
    /// press on the photo and a drag up or down.
    var curvePicker: TargetPicker? = nil
    var mixerPicker: TargetPicker? = nil
    /// A fit or actual-pixels request (the iPad's canvas bar).
    var zoomRequest: CanvasZoomRequest? = nil
    /// The screen's headroom as it changes (the iPad's canvas bar).
    var onHeadroom: (HeadroomSnapshot) -> Void = { _ in }
    @State private var headroom = HeadroomSnapshot()
    /// The crop pane's placement while its box is dragged.
    @State private var cropFreeze: CropLayout?
    /// The opening stage and the refining mark wait a moment before they
    /// show, so a quick open or refine passes without a flash.
    @State private var showsStage = false
    @State private var showsRefining = false

    /// Room around the crop in the crop pane, for its corners.
    static let cropMargin: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let layout = framed ? session.frameLayout : nil
            let placement = Placement(layout: layout, in: proxy.size, padding: framed ? framePadding : 0)
            ZStack(alignment: .topLeading) {
                if let layout, session.frame.isEnabled {
                    mat(layout, placement: placement)
                }
                canvas(viewport: placement.print.size)
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
        // A placement held from one visit to the crop pane never reaches the next.
        .onChange(of: cropping) {
            cropFreeze = nil
            // A hold never outlives the pane's change: the crop pane shows no original.
            holdingOriginal = false
        }
        // The new photo's embedded thumbnail until its first frame; over a
        // previous photo it covers that one entirely.
        .overlay { OpeningPlaceholder(placeholder, backdrop: editor.frame != nil) }
        .overlay(alignment: .top) { status.padding(.top, Space.s2) }
        // The card and the top capsule never show together: once there is
        // something to see (a thumbnail, a frame) the card goes at once and
        // the capsule carries the stage.
        .overlay { if showsOpeningCard { OpeningCard(stage: session.openingStage, fraction: session.fetchFraction) } }
    }

    /// Nothing to show yet: the stage goes in the middle of the empty canvas.
    private var showsOpeningCard: Bool { editor.frame == nil && editor.placeholder == nil }

    private var placeholder: OpeningPlaceholder.Content? {
        guard let id = editor.placeholderID, let image = editor.placeholder else { return nil }
        let size = editor.placeholderPixelSize.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        return OpeningPlaceholder.Content(id: id, image: image, pixelSize: size)
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

    private func canvas(viewport: CGSize) -> some View {
        let crop = cropLayout(viewport)
        return EDRCanvas(content: content(crop),
                  fitRequest: framed,
                  zoomRequest: zoomRequest,
                  onHeadroom: { headroom = $0; onHeadroom($0) },
                  onDrawableSize: { editor.canvasPixelSize = $0 },
                  onHoldOriginal: { holdingOriginal = $0 },
                  onError: { _ in session.notice = "ios.error.load" },
                  onTransform: { transform = $0 })
            .overlay {
                if cropping, let crop {
                    CropOverlay(layout: crop, adjusting: editor.editingParameter == RecipeEditor.geometryDragID,
                                freeze: $cropFreeze, write: { geometry in
                                    var recipe = editor.recipe
                                    recipe.geometry = geometry
                                    editor.setRecipe(recipe)
                                }, onEditing: { editor.editingGeometry($0) },
                                onCancel: { editor.endCropInteraction() })
                } else if !cropping {
                    adornments
                }
            }
            .overlay {
                // Not while the canvas draws the whole photo through the crop: the
                // photo's rectangle is then not the cropped photo's.
                if let whiteBalance, whiteBalance.isActive, !cropping, crop == nil, !framed {
                    WhiteBalanceTouchLayer(picker: whiteBalance, frames: whiteBalanceFrames)
                } else if !cropping, crop == nil, !framed {
                    if let curvePicker, curvePicker.isActive {
                        TargetPickTouchLayer(picker: curvePicker, imageFrame: transform?.imageFrame ?? .zero) {
                            Text("ipad.curve.pickHint")
                        }
                    } else if let mixerPicker, mixerPicker.isActive {
                        TargetPickTouchLayer(picker: mixerPicker, imageFrame: transform?.imageFrame ?? .zero) {
                            Text("ipad.mixer.pickHint")
                        }
                    }
                }
            }
    }

    /// What the eyedropper's loupe reads: the frames as the canvas composes them.
    private var whiteBalanceFrames: WhiteBalanceFrames {
        WhiteBalanceFrames(original: original.map { DisplayPair($0.display).base },
                           edited: editor.frame.map { DisplayPair($0.display).base },
                           shown: mode == .original ? .original : mode == .compare ? .compare : .edited,
                           splitRatio: splitRatio, imageFrame: transform?.imageFrame ?? .zero)
    }

    /// The crop pane's placement of the photo, drawn from whatever frame is
    /// shown (on entering, the cropped one lands on its crop until the whole
    /// photo arrives); also, once the pane is left, until the cropped frame
    /// arrives (the whole photo drawn through the crop, so it never shows
    /// uncropped). Nil outside the pane when the frame shown is not the whole photo.
    private func cropLayout(_ viewport: CGSize) -> CropLayout? {
        guard let frame = editor.frame, let source = editor.frameSource,
              CropLayout.drawsThroughGeometry(shown: frame.request.recipe.geometry, recipe: editor.recipe.geometry,
                                              cropping: cropping),
              viewport.width > 0, viewport.height > 0 else { return nil }
        if cropping, let cropFreeze { return cropFreeze.with(editor.recipe.geometry) }
        let photo = GeometrySize(width: Double(source.pixelSize.width), height: Double(source.pixelSize.height))
        return CropLayout(photo: photo, geometry: editor.recipe.geometry, viewport: viewport,
                          margin: cropping ? Self.cropMargin : 0)
    }

    /// The original of the shown photo, when there is one to compare with.
    private var original: EditorFrame? {
        editor.originalFrame.flatMap { $0.request.sourceID == editor.frame?.request.sourceID ? $0 : nil }
    }

    var mode: DisplayComposition.Mode {
        Self.mode(editor, comparison: comparison, holding: holdingOriginal, cropping: cropping)
    }

    /// What the canvas composes. While it draws through the geometry (the crop
    /// pane, and leaving it until the cropped frame arrives) it draws the edit
    /// alone, as the Mac's does; the comparison chosen comes back after.
    static func mode(_ editor: RecipeEditor, comparison: Comparison, holding: Bool,
                     cropping: Bool = false) -> DisplayComposition.Mode {
        if let frame = editor.frame,
           CropLayout.drawsThroughGeometry(shown: frame.request.recipe.geometry, recipe: editor.recipe.geometry,
                                           cropping: cropping) {
            return .edited
        }
        guard !cropping else { return .edited }
        let original = editor.originalFrame.flatMap { $0.request.sourceID == editor.frame?.request.sourceID ? $0 : nil }
        guard original != nil else { return .edited }
        if holding { return .original }
        switch comparison {
        case .original: return .original
        case .edited: return .edited
        case .split: return .compare
        }
    }

    private func content(_ crop: CropLayout?) -> EDRCanvasUIView.Content? {
        guard let frame = editor.frame, let source = editor.frameSource else { return nil }
        // Until the new photo's first frame arrives the previous one stays, at its
        // own size: its photo after the geometry it was rendered with.
        let size = frame.request.recipe.geometry.outputSize(of: source.pixelSize)
        let original = original
        let originalDetail = original == nil ? nil : editor.shownOriginalDetail
        return EDRCanvasUIView.Content(edited: DisplayPair(frame.display),
                                       original: original.map { DisplayPair($0.display) },
                                       editedDetail: editor.shownDetail.map { DisplayPair($0.display) },
                                       originalDetail: originalDetail.map { DisplayPair($0.display) },
                                       mode: mode, splitRatio: splitRatio,
                                       previewsAsSDR: editor.previewsAsSDR,
                                       imageSize: CGSize(width: size.width, height: size.height),
                                       geometry: crop?.display(clipsToCrop: !cropping, dimsOutsideCrop: cropping,
                                                               rendered: frame.request.recipe.geometry),
                                       clipping: clippingMasks)
    }

    /// Render's dead black and clipping masks while a white or black point is
    /// dragged.
    private var clippingMasks: ClippingMasks? {
        guard editor.showsClipping else { return nil }
        let masks = ClippingMasks(whole: editor.clippingMask?.texture, detail: editor.detailClippingMask?.texture)
        return masks.isEmpty ? nil : masks
    }

    /// The split divider and the badge, in the canvas's coordinates.
    @ViewBuilder private var adornments: some View {
        if let transform, transform.imageFrame.width > 0 {
            let image = transform.imageFrame
            let visible = image.intersection(CGRect(origin: .zero, size: transform.viewport))
            ZStack {
                if mode == .compare {
                    SplitOverlay(ratio: splitRatio, imageFrame: image,
                                 visibleRect: CGRect(origin: .zero, size: transform.viewport),
                                 originalLabel: Text("ios.view.original"), editedLabel: Text("ios.view.edited"),
                                 showsHDRBadge: showsHDR, hitWidth: SplitGeometry.touchHitWidth,
                                 onDrag: { splitRatio = $0 },
                                 onNudge: { splitRatio = min(max(splitRatio + $0, SplitGeometry.ratioRange.lowerBound),
                                                             SplitGeometry.ratioRange.upperBound) })
                }
                if !visible.isNull, badge != nil || refining {
                    HStack(spacing: Space.s2) {
                        if refining { RefiningMark() }
                        if let badge { badge }
                    }
                    .padding(Space.s3)
                    .frame(width: visible.width, height: visible.height, alignment: .topTrailing)
                    .position(x: visible.midX, y: visible.midY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.2), value: mode)
            .animation(.smooth(duration: 0.2), value: refining)
        }
    }

    /// A draft is shown while the full-quality preview is made: a small
    /// mark beside the badge, never over the controls, never blocking.
    private var refining: Bool { showsRefining && editor.isRefiningPreview && !cropping && !framed }

    /// Follow the rendered photo, including zero strength and group bypass,
    /// rather than controls whose replacement frame may still be rendering.
    private var showsHDR: Bool {
        editor.frame?.hasHDRContent == true && !editor.previewsAsSDR
    }

    /// As on the Mac canvas (PhotoBadgeKind): "HDR" over the edited photo,
    /// "Original" while Original is chosen; none while the original is held
    /// (the capsule says it) or on the frame, which previews the export.
    private var badge: AnyView? {
        guard !framed else { return nil }
        switch mode {
        case .edited where showsHDR:
            return AnyView(HDRBadge()
                .accessibilityLabel(headroom.potential > 1.01
                    ? Text("ios.display.edr \(Self.headroom(headroom.current)) \(Self.headroom(headroom.potential))")
                    : Text(verbatim: "HDR")))
        case .original where !holdingOriginal:
            return AnyView(Text("ios.view.original").hdrOverlayChip())
        default:
            return nil
        }
    }

    // MARK: Status

    private var status: some View {
        VStack(spacing: Space.s2) {
            if holdingOriginal, mode == .original, original != nil { capsule(Text("ios.canvas.original")) }
            // The original is asked for but not there: the canvas shows the
            // edit (unlabelled) until it is, or says it failed.
            if wantsOriginal, original == nil, editor.frame != nil, session.openingStage == nil {
                if editor.originalFailure != nil {
                    capsule(Text("ios.original.failed"), warning: true, action: retryRender)
                } else {
                    capsule(Text("ios.original.loading"), progress: true)
                }
            }
            if editor.aiStatus == .computing { capsule(Text("ios.ai.computing"), progress: true) }
            if case .failed = editor.aiStatus {
                capsule(Text("ios.ai.failed"), action: (Text("ios.common.retry"), { editor.retryModelGain() }))
            }
            if editor.sourceChanged { capsule(Text("ios.error.sourceChanged")) }
            // An edit's render failed: the canvas still shows the last frame,
            // which the controls no longer describe.
            if session.previewFailed { capsule(Text("ios.preview.failed"), warning: true, action: retryRender) }
            if let notice = session.notice { capsule(Text(notice)) }
            // Over the previous photo or the new one's thumbnail: say the new
            // one is on its way.
            if !showsOpeningCard, let stage = session.openingStage, showsStage || stage == .failed {
                stageCapsule(stage)
            }
        }
        .animation(.smooth(duration: 0.25), value: holdingOriginal)
        .animation(.smooth(duration: 0.25), value: session.openingStage)
        .animation(.smooth(duration: 0.25), value: session.previewFailed)
        .animation(.smooth(duration: 0.25), value: editor.originalFailure != nil)
        .animation(.smooth(duration: 0.25), value: original == nil)
        .animation(.smooth(duration: 0.25), value: editor.aiStatus)
        .task(id: session.openingStage != nil) {
            guard session.openingStage != nil else { showsStage = false; return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { showsStage = true }
        }
        .task(id: editor.isRefiningPreview) {
            guard editor.isRefiningPreview else { showsRefining = false; return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { showsRefining = true }
        }
        .task(id: session.notice) {
            guard session.notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { session.notice = nil }
        }
    }

    /// Original, Split or the canvas held.
    private var wantsOriginal: Bool { !cropping && (holdingOriginal || comparison != .edited) }

    /// Renders the current recipe again after a failure (the next edit would too).
    private var retryRender: (label: Text, run: () -> Void)? {
        (Text("ios.common.retry"), { editor.retryRendering() })
    }

    /// The opening stage in one capsule that stays put while its words
    /// change: the old words go at once and the new ones fade in, so two
    /// stages never overlap.
    private func stageCapsule(_ stage: EditingSession.OpeningStage) -> some View {
        HStack(spacing: Space.s2) {
            if stage == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hdr.warn)
            } else {
                ProgressView().controlSize(.mini)
            }
            OpeningCard.swapping(stage)
            // A download from iCloud reports how far it is: say so here too,
            // when the card in the middle is not on screen.
            if stage == .fetching, let fraction = session.fetchFraction, fraction > 0, fraction < 1 {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// A status line in a glass capsule. One with an action is a button as
    /// a whole, so the short capsule is easy to hit; the others let touches
    /// through to the canvas.
    @ViewBuilder
    private func capsule(_ text: Text, progress: Bool = false, warning: Bool = false,
                         action: (label: Text, run: () -> Void)? = nil) -> some View {
        let content = HStack(spacing: Space.s2) {
            if progress { ProgressView().controlSize(.mini) }
            if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hdr.warn) }
            text
            if let action {
                action.label
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.hdr.accent)
                    .padding(.leading, Space.s1)
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .contentShape(.capsule)
        if let action {
            Button(action: action.run) { content }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            content
                .glassEffect(.regular, in: .capsule)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    static func headroom(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(1))) + "×"
    }
}

/// A small spinner in a glass circle at the photo's corner: the draft on
/// screen is being refined. Touches go through to the canvas.
struct RefiningMark: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 24, height: 24)
            .glassEffect(.regular, in: .circle)
            .accessibilityElement()
            .accessibilityLabel(Text("ios.preview.refining"))
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// Before a photo's first frame the canvas is empty: this says what the open
/// is waiting for, in the middle of it. Getting the photo shows how much has
/// arrived when the system reports it (a download from iCloud). With no
/// stage yet (the request is being accepted) it reads as fetching.
struct OpeningCard: View {
    let stage: EditingSession.OpeningStage?
    let fraction: Double?

    var body: some View {
        let stage = stage ?? .fetching
        VStack(spacing: Space.s3) {
            if stage == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.hdr.warn)
            } else {
                ProgressView().controlSize(.large)
            }
            Self.swapping(stage)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            if stage == .fetching, let fraction, fraction > 0, fraction < 1 {
                ProgressView(value: fraction)
                    .frame(width: 140)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s4)
        .frame(minWidth: 180)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(.smooth(duration: 0.25), value: stage)
        .animation(.smooth(duration: 0.25), value: fraction == nil)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
        // Fades in on an empty canvas; leaves at once when a thumbnail or
        // frame arrives, so it never overlaps the top capsule.
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }

    /// The stage's words, replaced in place: the old ones are removed
    /// without a transition and the new ones fade in quickly.
    static func swapping(_ stage: EditingSession.OpeningStage) -> some View {
        text(stage)
            .id(stage)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15)), removal: .identity))
    }

    static func text(_ stage: EditingSession.OpeningStage) -> Text {
        switch stage {
        case .fetching: Text("ios.open.fetching")
        case .reading: Text("ios.open.reading")
        case .loadingDecoder: Text("ios.open.loadingDecoder")
        case .developing: Text("ios.open.developing")
        case .preparingPreview: Text("ios.open.preparingPreview")
        case .rendering: Text("ios.open.rendering")
        case .failed: Text("ios.open.failed")
        }
    }
}
