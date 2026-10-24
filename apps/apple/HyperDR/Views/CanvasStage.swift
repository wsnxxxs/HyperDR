import SwiftUI
import HyperDRDesign
import HyperDRRecipe

/// The photograph on the canvas: `PreviewCanvas` draws only the photo's
/// pixels, and everything around them -- rounded corners, shadow, badge,
/// progress, errors -- is drawn here, aligned to `canvas.imageFrame`
/// (batch 3 §3.5).
///
/// With focus, F fits the photo to the window, + / − zoom (§12 Q9), C
/// compares, holding Space shows the original and Esc lets it go. In the
/// crop pane Return finishes the crop and Esc puts back the geometry the
/// pane opened with (one undo step) and leaves it. The keys
/// are taken here, not by `PreviewCanvas`, and only while the canvas itself
/// has focus, so a focused text field keeps them. Holding the pointer on
/// the photo for 240 ms shows the original too (`PressAndHold`).
///
/// The canvas takes focus itself when a photo opens and when it is clicked;
/// a ring then would frame it permanently. Like the web stage's
/// `:focus-visible`, the ring shows only when focus arrives another way --
/// Tab, or an assistive technology (parity G-16).
struct CanvasStage: View {
    let model: EditorModel
    let window: EditorWindowState
    /// Whether the inspector is showing: the zebra legend is on the canvas
    /// only while it is not.
    var showsInspector = true
    /// What a drag over the canvas says, if anything.
    var dropNotice: DropNotice? = nil

    @Environment(ViewerSessionState.self) private var session
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var focused: Bool
    @State private var hint = CanvasHintState()
    @State private var hold: PressAndHold
    @State private var peek: PeekHolds

    init(model: EditorModel, window: EditorWindowState, showsInspector: Bool = true, dropNotice: DropNotice? = nil) {
        self.model = model
        self.window = window
        self.showsInspector = showsInspector
        self.dropNotice = dropNotice
        let peek = PeekHolds(begin: { [weak model] in
            if let model, model.viewMode != .original { model.beginPeekOriginal() }
        }, end: { [weak model] in model?.endPeekOriginal() })
        _peek = State(initialValue: peek)
        _hold = State(initialValue: PressAndHold(begin: { peek.hold(.pointer) }, end: { peek.release(.pointer) }))
    }
    /// The editor's placeholder while the canvas has no frame of its own; a
    /// photo replacing another keeps the old one on screen instead.
    private var openingPlaceholder: OpeningPlaceholder.Content? {
        let editor = model.editor
        guard model.canvas.imageFrame == nil, let id = editor.placeholderID, let image = editor.placeholder else { return nil }
        let size = editor.placeholderPixelSize.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        return OpeningPlaceholder.Content(id: id, image: image, pixelSize: size)
    }

    /// The current focus was given by the canvas itself, not the keyboard.
    @State private var focusedByPointer = false
    /// The geometry when the crop pane opened, for Esc.
    @State private var cropEntry: Geometry?

    var body: some View {
        PreviewCanvas(model: model, pointer: pointer)
            // Until the first photo's first frame: its embedded thumbnail,
            // fitted as the canvas will fit the photo, fading out as the frame lands.
            .overlay { OpeningPlaceholder(openingPlaceholder) }
            .background { PhotoShadow(frame: photoFrame) }
            .overlay { PhotoCorners(frame: photoFrame) }
            .overlay { if model.cropLayout == nil { PhotoBadge(model: model) } }
            .overlay {
                if model.isCropping, let crop = model.cropLayout {
                    CropOverlay(layout: crop, adjusting: model.editor.editingParameter == RecipeEditor.geometryDragID,
                                freeze: Bindable(model).cropFreeze, write: { model.setGeometry($0) },
                                onEditing: { model.editor.editingGeometry($0) })
                }
            }
            .overlay {
                CanvasFloating(model: model, window: window, hint: hint, showsInspector: showsInspector,
                               dropNotice: dropNotice) { editing in
                    if editing { hint.dismiss() }
                }
            }
            .overlay { if focused && !focusedByPointer { FocusRing() } }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onChange(of: focused) { _, now in if !now { focusedByPointer = false } }
            .onKeyPress(characters: Self.keys, action: handle)
            .onKeyPress(keys: [.space], phases: [.down, .repeat, .up], action: handleSpace)
            .onKeyPress(.escape) {
                if model.isPeekingOriginal {
                    releaseHolds()
                    return .handled
                }
                guard model.isCropping else { return .ignored }
                cancelCrop()
                return .handled
            }
            .onKeyPress(.return) {
                guard model.isCropping else { return .ignored }
                model.isCropping = false
                return .handled
            }
            .onChange(of: CropEntryTrigger(cropping: model.isCropping, serial: model.photoSerial), initial: true) { _, trigger in
                cropEntry = trigger.cropping ? model.editor.recipe.geometry : nil
            }
            // One observation for both what the hint says and which photo it
            // is for, so the first photo's hint is announced once.
            .onChange(of: HintTrigger(serial: model.photoSerial, key: model.viewerHintKey), initial: true) { _, trigger in
                hint.observe(serial: trigger.serial, key: trigger.key, session: session, covered: legendIsShowing)
            }
            // Pasting an image that is not a file says so in the hint's place.
            .onChange(of: model.notice, initial: true) {
                guard model.notice == .clipboardImageUnsupported else { return }
                hint.announce("paste.imageData")
                model.notice = nil
            }
            // The legend takes the hint's place, and the hint does not come
            // back when the legend goes.
            .onChange(of: legendIsShowing) { if legendIsShowing { hint.dismiss() } }
            // Closing the document, or a photo with another name, starts the
            // next hint afresh.
            .onChange(of: model.document?.name) { hint.reset() }
            .onDisappear { releaseHolds() }
            .task(id: hint.shown) {
                guard hint.shown != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { hint.dismiss() }
            }
            // A key up never arrives once the window is not key.
            .onChange(of: activeState) { if activeState == .inactive { releaseHolds() } }
            .onChange(of: focused) { _, now in if !now { releaseHolds() } }
            .simultaneousGesture(TapGesture().onEnded { takeFocus() })
            // A newly opened photo takes the keys, as the web stage does.
            .onChange(of: model.document?.name, initial: true) {
                if model.document != nil { takeFocus() } else { focused = false }
            }
    }

    /// The photo's rectangle for its shadow and corners: none while the crop
    /// pane draws through the geometry, which is not the canvas's rectangle.
    private var photoFrame: CGRect? {
        model.cropLayout == nil ? model.canvas.imageFrame : nil
    }

    /// What the canvas reports of the pointer: a press starts the 240 ms
    /// hold and dismisses the hint; the wheel and a pinch dismiss it.
    private var pointer: CanvasPointerHandlers {
        let hold = self.hold
        return CanvasPointerHandlers(
            down: { [hint] point in hint.dismiss(); hold.press(at: point) },
            drag: { hold.drag(to: $0) },
            up: { hold.release() },
            zoomGesture: { [hint] in hint.dismiss() })
    }

    /// Lets go of whatever holds the original, from every source.
    private func releaseHolds() {
        hold.release()
        peek.releaseAll()
        model.endPeekOriginal()
    }

    private var legendIsShowing: Bool {
        !CanvasAdornments.legendRows(model: model, showsInspector: showsInspector).isEmpty
    }

    /// Esc in the crop pane: the geometry it opened with, and back to Adjust.
    private func cancelCrop() {
        if let cropEntry, !model.isEditingLocked, model.editor.recipe.geometry != cropEntry {
            model.setGeometry(cropEntry)
        }
        model.isCropping = false
    }

    private func takeFocus() {
        focusedByPointer = true
        focused = true
    }

    private static let keys = CharacterSet(charactersIn: "fF+=-cC")

    /// Holding Space shows the original at once (no 240 ms: the key is a
    /// deliberate act); letting go brings the edit back.
    private func handleSpace(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        hint.dismiss()
        switch press.phase {
        case .down: peek.hold(.key)
        case .up: peek.release(.key)
        default: break
        }
        return .handled
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // ⌘, ⌥ and ⌃ combinations belong to the menus.
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        hint.dismiss()
        let canvas = model.canvas
        switch press.characters {
        case "c", "C": model.toggleCompare()
        case "f", "F": canvas.fitToWindow()
        // "=" is + without Shift on most layouts.
        case "+", "=": canvas.zoomIn()
        case "-": canvas.zoomOut()
        default: return .ignored
        }
        return .handled
    }
}

/// The crop pane opening, or another photo while it is open.
private struct CropEntryTrigger: Equatable {
    var cropping: Bool
    var serial: Int
}

/// What decides the hint: the photo on the canvas and what can be done now.
private struct HintTrigger: Equatable {
    var serial: Int
    var key: String?
}

// MARK: - Frame

/// The keyboard focus ring, in the colour used for focus on the photograph
/// (the accent is too dark against the backdrop).
struct FocusRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sm)
            .strokeBorder(Color.hdr.overlayInk, lineWidth: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The photo's shadow, drawn on the backdrop under the transparent canvas.
private struct PhotoShadow: View {
    let frame: CGRect?

    var body: some View {
        if let frame {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.hdr.previewBackdrop)
                .elevation(.md)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }
}

/// Rounds the photo's corners by covering them with the backdrop: the
/// canvas is an AppKit layer that SwiftUI cannot clip.
private struct PhotoCorners: View {
    let frame: CGRect?

    var body: some View {
        if let frame {
            Canvas { context, _ in
                var path = Path(frame)
                path.addRoundedRect(in: frame, cornerSize: CGSize(width: Radius.sm, height: Radius.sm))
                context.fill(path, with: .color(Color.hdr.previewBackdrop), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// "HDR" over the edited photo when it has extended range; "Original" while
/// the original is shown. Pinned to the visible part of the photo, so it
/// stays on screen when zoomed in.
private struct PhotoBadge: View {
    let model: EditorModel

    var body: some View {
        GeometryReader { proxy in
            if let frame = model.canvas.imageFrame?.intersection(CGRect(origin: .zero, size: proxy.size)),
               !frame.isNull, let badge {
                badge
                    .padding(Space.s3)
                    .frame(width: frame.width, height: frame.height, alignment: .topTrailing)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
    }

    private var badge: AnyView? {
        switch PhotoBadgeKind(viewMode: model.viewMode, originalAvailable: model.isAvailable(.original),
                              hasHDR: model.showsHDRBadge,
                              isPeeking: model.isPeekingOriginal) {
        case .original:
            AnyView(Text("stage.badgeOriginal")
                .hdrOverlayChip()
                .help("stage.titleOriginal"))
        case .hdr:
            AnyView(HDRBadge().help("stage.titleHdr"))
        case nil:
            nil
        }
    }
}

/// Which badge the photo carries (parity G-14).
enum PhotoBadgeKind: Equatable {
    case original, hdr

    /// "Original" while the original is shown. "HDR" over the edited photo
    /// when the shown effect frame carries HDR, even on an SDR screen. The
    /// compare divider uses the same content fact. While held, the original
    /// is named by the label in the middle instead.
    init?(viewMode: ViewMode, originalAvailable: Bool, hasHDR: Bool,
          isPeeking: Bool = false) {
        guard !isPeeking else { return nil }
        switch viewMode {
        case .original where originalAvailable:
            self = .original
        case .edited where hasHDR:
            self = .hdr
        default:
            return nil
        }
    }
}

// MARK: - Floating things

/// What floats over the photo: the compare divider and legend, the status
/// card or chip, the export capsule. The foot of the canvas is shared: the
/// card, chip and capsule report their height and the legend and hint keep
/// above them (`CanvasBottomReserve`), however the sentences wrap.
struct CanvasFloating: View {
    let model: EditorModel
    let window: EditorWindowState
    let hint: CanvasHintState
    let showsInspector: Bool
    /// What a drag over the canvas says, if anything. It reads the foot's
    /// reserve and adds none: it comes and goes with the pointer, and nothing
    /// else may move for it.
    var dropNotice: DropNotice? = nil
    var busyAlreadyShown = false
    var onSplitEditing: (Bool) -> Void = { _ in }

    /// What the card, chip and capsule take at the canvas's foot.
    @State private var foot = CanvasBottomReserve()
    /// Where, left to right, the things that the chip may share a column with are.
    @State private var columns: [String: ClosedRange<CGFloat>] = [:]

    private func extent(_ name: String) -> ClosedRange<CGFloat>? { columns[name] }

    var body: some View {
        let legendColumns = extent("legend") ?? extent("hint")
        let legendLift = CanvasBottomReserve.lift(foot, columns: legendColumns, chip: extent("chip"))
        ZStack {
            CanvasAdornments(model: model, hint: hint, showsInspector: showsInspector,
                             bottomReserve: legendLift, onSplitEditing: onSplitEditing)
                .hdrAnimation(Motion.standard, value: legendLift)
            CanvasStatus(model: model, window: window, busyAlreadyShown: busyAlreadyShown)
            if !showsInspector {
                ExportCanvasCapsule(model: model, window: window,
                                    lift: CanvasBottomReserve.capsuleLift(foot, capsule: extent("capsule"), chip: extent("chip")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            if let notice = model.canvasNotice, dropNotice == nil {
                let lift = CanvasBottomReserve.lift(foot, columns: extent("notice"), chip: extent("chip"))
                CanvasNoticeChip(notice: notice) { model.dismissRestoreNotice() }
                    .reportsCanvasFrame(name: "notice")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, lift > 0 ? lift + Space.s2 : Space.s4 - Layout.canvasGutter)
                    .transition(.opacity)
            }
            if let dropNotice {
                let lift = CanvasBottomReserve.lift(foot, columns: extent("drop"), chip: extent("chip"))
                DropNoticeChip(notice: dropNotice)
                    .reportsCanvasFrame(name: "drop")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    // Above the card and the capsule; with nothing there, where
                    // the chip sat before it moved inside the canvas's gutter.
                    .padding(.bottom, lift > 0 ? lift + Space.s2 : Space.s4 - Layout.canvasGutter)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(CanvasBottomReserveKey.self) { foot = $0 }
        .onPreferenceChange(CanvasFloatingFramesKey.self) { frames in
            let next = frames.mapValues { $0.minX...$0.maxX }
            if next != columns { columns = next }
        }
        // A drag over the canvas is the user acting on it: the hint steps aside.
        .onChange(of: dropNotice != nil) { _, dragging in
            if dragging { hint.dismiss(); if model.canvasNotice != nil { model.dismissRestoreNotice() } }
        }
        .hdrAnimation(value: model.canvasNotice)
    }
}

// MARK: - Status

/// What the canvas is doing: reading or building the first frame, refreshing
/// an existing one, a failed refresh over the kept frame, or a photo with no
/// frame at all.
struct CanvasStatus: View {
    let model: EditorModel
    let window: EditorWindowState

    /// Work over an existing frame shows only once it has taken 300 ms, so
    /// quick refreshes do not flicker.
    @State private var showsBusy: Bool
    @Environment(\.locale) private var locale

    /// `busyAlreadyShown` skips the 300 ms wait, for views that are laid out
    /// without being on screen (tests).
    init(model: EditorModel, window: EditorWindowState, busyAlreadyShown: Bool = false) {
        self.model = model
        self.window = window
        _showsBusy = State(initialValue: busyAlreadyShown)
    }

    var body: some View {
        ZStack {
            if let document = model.document {
                if hasFrame {
                    if model.sourceUnavailable != nil {
                        SourceMissingBanner(isChecking: model.isRelinking) { window.locateSource() }
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(Space.s3)
                    } else if model.sourceChanged {
                        SourceMissingBanner(kind: .changed) { model.reopenChangedSource() }
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(Space.s3)
                    } else if let error = document.previewError {
                        let text = ErrorText(error)
                        PreviewErrorBanner(title: Text(text.title), message: Text(text.message), detail: text.body) {
                            model.editor.retryRendering()
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(Space.s3)
                    } else if let detail = originalFailure {
                        PreviewErrorBanner(title: Text("preview.originalFailed"), message: nil, detail: detail) {
                            model.editor.retryRendering()
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(Space.s3)
                    }
                    if document.isPreparingCameraSupport {
                        CameraSupportCard(fileName: document.name, canCancel: model.canCancelOpen, cancel: cancelOpen)
                            .reportsCanvasFoot(\.status, gap: Space.s4, name: "status")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(Space.s4)
                            .transition(.opacity)
                    } else if showsBusy, let label = busyLabel(document) {
                        busyChip(label, document: document)
                            .reportsCanvasFoot(\.chip, gap: Space.s3, name: "chip")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(Space.s3)
                    }
                } else {
                    switch document.phase {
                    case .opening, .rendering:
                        Group {
                            if document.isPreparingCameraSupport {
                                CameraSupportPanel(fileName: document.name, canCancel: model.canCancelOpen, cancel: cancelOpen)
                                    .transition(.opacity)
                            } else {
                                FirstFrameProgress(label: busyLabel(document) ?? "stage.generating",
                                                   slowFileName: document.isOpeningSlowly && model.canCancelOpen ? document.name : nil,
                                                   cancel: cancelOpen)
                            }
                        }
                        .modifier(OverPlaceholder(isOn: model.editor.placeholder != nil))
                    case .failed(let error):
                        FirstFrameFailure(text: ErrorText(error), engineFailed: model.engine.failure != nil) {
                            window.isImporting = true
                        }
                    case .ready:
                        EmptyView()
                    }
                }
            }
        }
        .animation(Motion.ease(), value: showsBusy)
        .hdrAnimation(value: model.document?.isPreparingCameraSupport == true)
        .onChange(of: model.document?.isPreparingCameraSupport == true) { _, preparing in
            if preparing { CameraSupportAnnouncement.post("raw.preparing.announce", locale: locale) }
        }
        .onChange(of: model.document?.isOpeningSlowly == true) { _, slow in
            if slow, let name = model.document?.name {
                CameraSupportAnnouncement.post("open.slow.announce %@", locale: locale, name)
            }
        }
        .task(id: isBusy) {
            guard isBusy else { showsBusy = false; return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsBusy = true }
        }
    }

    private func cancelOpen() { OpenCancellation.cancel(model, locale: locale) }

    /// The original preview failed while the original is asked for (Original,
    /// Split or held): the canvas shows the edit in its place, so say so.
    private var originalFailure: String? {
        guard model.viewMode != .edited || model.isPeekingOriginal else { return nil }
        return model.editor.originalFailure
    }

    /// "Reading the photo…" in the corner; once it is slow, with Cancel.
    @ViewBuilder private func busyChip(_ label: LocalizedStringKey, document: DocumentState) -> some View {
        if document.isOpeningSlowly, model.canCancelOpen {
            SlowOpenChip(label: label, fileName: document.name, cancel: cancelOpen)
        } else {
            Label { Text(label) } icon: { CanvasSpinner(size: 12) }
                .frame(height: BusyChip.contentHeight)
                .hdrOverlayChip()
        }
    }

    /// Whether the canvas draws a photo. Until the first frame (and briefly
    /// before the first layout) it has no rectangle.
    private var hasFrame: Bool { model.canvas.imageFrame != nil }

    private var isBusy: Bool {
        guard hasFrame, let document = model.document else { return false }
        return busyLabel(document) != nil
    }

    private func busyLabel(_ document: DocumentState) -> LocalizedStringKey? {
        switch document.phase {
        case .opening, .rendering:
            // The editor's own phase once it has one (OPENING.md): coarse
            // attribution, not a percentage.
            switch model.editor.openingPhase {
            case .reading: "stage.reading"
            case .loadingDecoder: "stage.loadingDecoder"
            case .developing: "stage.decoding"
            case .preparingPreview: "stage.analyzing"
            case .rendering: "stage.generating"
            case nil: document.phase == .opening ? "stage.reading" : "stage.generating"
            }
        case .ready, .failed: document.isRefreshing ? "mac.canvas.refreshing" : nil
        }
    }
}

/// Over the opening thumbnail the panel's light text needs a dark plate, as
/// the canvas chips have; on the empty canvas it needs none.
private struct OverPlaceholder: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .padding(isOn ? Space.s5 : 0)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: Radius.xl)
                        .fill(Color.hdr.overlay)
                        .overlay { RoundedRectangle(cornerRadius: Radius.xl).strokeBorder(Color.hdr.overlayLine) }
                        .transition(.opacity)
                }
            }
            .animation(Motion.ease(), value: isOn)
    }
}

/// A refresh failed; the previous frame stays on the canvas until Retry (or
/// the next edit) renders the current recipe.
private struct PreviewErrorBanner: View {
    let title: Text
    let message: Text?
    /// Developer-facing, in the tooltip.
    let detail: String
    let retry: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    title.fontWeight(.semibold)
                    if let message { message.foregroundStyle(Color.hdr.overlayMuted) }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hdr.warn)
            }
            .accessibilityElement(children: .combine)
            Button(action: retry) {
                Text("preview.retry")
                    .font(.system(size: TypeScale.Size.caption, weight: .semibold))
                    .foregroundStyle(Color.hdr.overlayInk)
                    .padding(.horizontal, Space.s2)
                    .frame(height: BusyChip.height)
                    .background(hovered ? Color.hdr.overlayHover : .clear, in: .rect(cornerRadius: Radius.md))
                    .contentShape(.rect(cornerRadius: Radius.md))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .hdrOverlayChip()
        .help(Text(verbatim: detail))
    }
}

struct FirstFrameProgress: View {
    let label: LocalizedStringKey
    /// Set once the open is slow: the file's name and a way out go under the stage text.
    var slowFileName: String? = nil
    /// Offer the way out even with no file name to show (a restore that is
    /// still looking for its photograph).
    var offersCancel = false
    var cancel: () -> Void = {}

    var body: some View {
        VStack(spacing: Space.s3) {
            VStack(spacing: Space.s3) {
                CanvasSpinner(size: 22)
                Text(label)
                    .font(Font.hdr.control)
            }
            .foregroundStyle(Color.hdr.overlayInk)
            .accessibilityElement(children: .combine)
            if slowFileName != nil || offersCancel { SlowOpenDetails(fileName: slowFileName, cancel: cancel) }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The open photo has no frame to show (for example, Metal is unavailable).
private struct FirstFrameFailure: View {
    let text: ErrorText
    let engineFailed: Bool
    let chooseAnother: () -> Void

    var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.hdr.warn)
            Text(text.title)
                .font(Font.hdr.heading)
                .foregroundStyle(Color.hdr.overlayInk)
            Text(verbatim: text.body)
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.overlayMuted)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("mac.canvas.chooseAnother", action: chooseAnother)
                .buttonStyle(.hdrSecondary)
                .disabled(engineFailed)
                .padding(.top, Space.s1)
        }
        .frame(maxWidth: 420)
        .padding(Space.s6)
        .environment(\.colorScheme, .dark)
    }
}
