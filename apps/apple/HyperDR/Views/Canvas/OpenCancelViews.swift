import AppKit
import SwiftUI
import HyperDRDesign

/// Stopping an open that has not produced a first frame (raw-states §9):
/// the same for a RAW and anything else, for the button and for Escape. The
/// model goes back to what was there before; there is no alert and no hint,
/// only the announcement.
@MainActor enum OpenCancellation {
    static func cancel(_ model: EditorModel, locale: Locale = .current) {
        guard model.canCancelOpen else { return }
        model.endPeekOriginal()
        model.cancelOpen()
        CameraSupportAnnouncement.post("open.cancelled", locale: locale)
    }
}

/// The first frame is slow and there is no photograph yet: the file's name
/// and a Cancel under the progress, as short as the stage text allows
/// (raw-states §9.2).
struct SlowOpenDetails: View {
    /// Nil while the photograph is still being found (a slow restore).
    let fileName: String?
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Space.s3) {
            if let fileName {
                Text(verbatim: fileName)
                    .font(Font.hdr.readout)
                    .foregroundStyle(Color.hdr.overlayMuted)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 320)
            }
            Button("open.cancel", action: cancel)
                .buttonStyle(.hdrSecondary)
                .keyboardShortcut(.cancelAction)
                .help(Text("open.cancel.help"))
                .accessibilityLabel(fileName.map { Text("open.cancel.a11y \($0)") } ?? Text("open.cancel"))
        }
    }
}

/// The corner chip's height, with and without Cancel (R-V7, N8): the chip's
/// own padding goes round whatever it holds, so the content is made this
/// much less, and the Cancel button's hover plate (26 pt) overhangs the
/// padding it cancels with a negative inset.
enum BusyChip {
    static let height: CGFloat = 26
    static var contentHeight: CGFloat { height - 2 * Space.s1 }
}

/// The busy chip over an earlier photograph with Cancel after its text: a
/// thin dot and a half-bold word, in the chip's own place and height.
struct SlowOpenChip: View {
    let label: LocalizedStringKey
    let fileName: String
    let cancel: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Space.s2) {
            Label { Text(label) } icon: { CanvasSpinner(size: 12) }
            Text(verbatim: "·").foregroundStyle(Color.hdr.overlayMuted).accessibilityHidden(true)
            Button(action: cancel) {
                Text("open.cancel")
                    .font(.system(size: TypeScale.Size.caption, weight: .semibold))
                    .foregroundStyle(Color.hdr.overlayInk)
                    .padding(.horizontal, Space.s2)
                    .frame(height: BusyChip.height)
                    .background(hovered ? Color.hdr.overlayHover : .clear, in: .rect(cornerRadius: Radius.md))
                    .contentShape(.rect(cornerRadius: Radius.md))
                    .padding(.vertical, -Space.s1)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .keyboardShortcut(.cancelAction)
            .help(Text("open.cancel.help"))
            .accessibilityLabel(Text("open.cancel.a11y \(fileName)"))
        }
        .frame(height: BusyChip.contentHeight)
        .hdrOverlayChip()
    }
}

// MARK: - Escape

/// Escape cancels an open that has not been committed, whenever it is
/// pressed and wherever the focus is (raw-states §9.4). Above it come
/// what a sheet, an alert, a popover or a menu owns; below it comes
/// letting go of the original. Taking the key here, not in the canvas,
/// is what makes it work with no focus on the canvas.
@MainActor enum OpenCancelKeyRule {
    struct Context {
        var isKeyWindow: Bool
        var hasAttachedSheet: Bool
        var hasModalWindow: Bool
        var firstResponder: NSResponder?
    }

    static let escapeKeyCode: UInt16 = 53

    /// Cancels the open and returns true when `event` is a plain Escape for
    /// this window; false when it should go on.
    static func handle(_ event: NSEvent, context: Context, model: EditorModel, locale: Locale = .current) -> Bool {
        guard event.type == .keyDown, event.keyCode == escapeKeyCode,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              context.isKeyWindow, !context.hasAttachedSheet, !context.hasModalWindow,
              !EditorModel.routesUndoToText(context.firstResponder),
              model.canCancelOpen else { return false }
        OpenCancellation.cancel(model, locale: locale)
        return true
    }
}

/// Owns the local monitor of one editor window.
@MainActor final class OpenCancelKeyMonitor {
    private var monitor: Any?
    private weak var window: NSWindow?

    func install(window: NSWindow, model: EditorModel) {
        remove()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak model] event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated {
                guard let self, let window = self.window, let model, event.window === window else { return false }
                let context = OpenCancelKeyRule.Context(
                    isKeyWindow: window.isKeyWindow, hasAttachedSheet: window.attachedSheet != nil,
                    hasModalWindow: NSApp.modalWindow != nil, firstResponder: window.firstResponder)
                return OpenCancelKeyRule.handle(event, context: context, model: model)
            }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
