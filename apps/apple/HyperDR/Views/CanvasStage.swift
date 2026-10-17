import SwiftUI
import HyperDRDesign

/// The photograph on the canvas: `PreviewCanvas` draws only the photo's
/// pixels, and everything around them -- rounded corners, shadow, badge,
/// progress, errors -- is drawn here, aligned to `canvas.imageFrame`
/// (batch 3 §3.5).
///
/// With focus, F fits the photo to the window and + / − zoom (§12 Q9). The
/// keys are taken here, not by `PreviewCanvas`, and only while the canvas
/// itself has focus, so a focused text field keeps them.
struct CanvasStage: View {
    let model: EditorModel
    let window: EditorWindowState

    @FocusState private var focused: Bool

    var body: some View {
        PreviewCanvas(model: model)
            .background { PhotoShadow(frame: model.canvas.imageFrame) }
            .overlay { PhotoCorners(frame: model.canvas.imageFrame) }
            .overlay { PhotoBadge(model: model) }
            .overlay { CanvasStatus(model: model, window: window) }
            .focusable()
            // The canvas takes focus whenever a photo opens, so the system
            // ring would frame it permanently; the web stage likewise shows
            // no ring unless focused from the keyboard.
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(characters: Self.keys, action: handle)
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            // A newly opened photo takes the keys, as the web stage does.
            .onChange(of: model.document?.name, initial: true) { focused = model.document != nil }
    }

    private static let keys = CharacterSet(charactersIn: "fF+=-")

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // ⌘, ⌥ and ⌃ combinations belong to the menus.
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        let canvas = model.canvas
        switch press.characters {
        case "f", "F": canvas.fitToWindow()
        // "=" is + without Shift on most layouts.
        case "+", "=": canvas.zoomIn()
        case "-": canvas.zoomOut()
        default: return .ignored
        }
        return .handled
    }
}

// MARK: - Frame

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
        switch model.viewMode {
        case .original where model.isAvailable(.original):
            AnyView(Text("stage.badgeOriginal")
                .hdrOverlayChip()
                .help("stage.titleOriginal"))
        case .edited where hasExtendedRange:
            AnyView(HDRBadge().help("stage.titleHdr"))
        default:
            nil
        }
    }

    /// The photo is HDR or carries an HDR rendition, or the edited frame
    /// shows gain above SDR white.
    private var hasExtendedRange: Bool {
        if let domain = model.document?.source?.domain, domain == .hdr || domain == .dual { return true }
        return (model.display.gainWeight ?? 0) > 0
    }
}

// MARK: - Status

/// What the canvas is doing: reading or building the first frame, refreshing
/// an existing one, a failed refresh over the kept frame, or a photo with no
/// frame at all.
private struct CanvasStatus: View {
    let model: EditorModel
    let window: EditorWindowState

    /// Work over an existing frame shows only once it has taken 300 ms, so
    /// quick refreshes do not flicker.
    @State private var showsBusy = false

    var body: some View {
        ZStack {
            if let document = model.document {
                if hasFrame {
                    if let error = document.previewError {
                        PreviewErrorBanner(text: ErrorText(error))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(Space.s3)
                    }
                    if showsBusy, let label = busyLabel(document) {
                        Label { Text(label) } icon: { ProgressView().controlSize(.mini) }
                            .hdrOverlayChip()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(Space.s3)
                    }
                } else {
                    switch document.phase {
                    case .opening, .rendering:
                        FirstFrameProgress(label: busyLabel(document) ?? "stage.generating")
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
        .task(id: isBusy) {
            guard isBusy else { showsBusy = false; return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsBusy = true }
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
        case .opening: "stage.reading"
        case .rendering: "stage.generating"
        case .ready, .failed: document.isRefreshing ? "mac.canvas.refreshing" : nil
        }
    }
}

/// A refresh failed; the previous frame stays on the canvas.
private struct PreviewErrorBanner: View {
    let text: ErrorText

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).fontWeight(.semibold)
                Text(text.message).foregroundStyle(Color.hdr.overlayMuted)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hdr.warn)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .hdrOverlayChip()
        .help(Text(verbatim: text.body))
        .accessibilityElement(children: .combine)
    }
}

private struct FirstFrameProgress: View {
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: Space.s3) {
            ProgressView().controlSize(.regular)
            Text(label)
                .font(Font.hdr.control)
        }
        .foregroundStyle(Color.hdr.overlayInk)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
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
