import SwiftUI

/// The editor's menu commands. They reach the frontmost editor window through
/// focused scene values, so they disable themselves when no editor window is
/// key.
///
/// The canvas's single-key shortcuts (F, +, −) are handled by `CanvasStage`,
/// only while the canvas has focus; C and hold-Space belong to M2.
/// PreviewCanvas itself never handles keyboard input (batch 3 §12 Q9).
struct EditorCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            OpenCommand()
        }
        CommandGroup(before: .toolbar) {
            ZoomCommands()
            Divider()
        }
        #if DEBUG
        CommandMenu("mac.menu.developer") {
            DiagnosticsCommand()
            // S12 spike tool; not localized.
            Button { StressWindow.shared.show() } label: { Text(verbatim: "Inspector Stress (S12)") }
        }
        #endif
    }
}

/// File ▸ Open… (⌘O): shows the same panel as the toolbar's open button.
private struct OpenCommand: View {
    @FocusedValue(EditorModel.self) private var model
    @FocusedValue(EditorWindowState.self) private var window

    var body: some View {
        Button("mac.menu.open") { window?.isImporting = true }
            .keyboardShortcut("o")
            .disabled(window == nil || model?.engine.failure != nil)
    }
}

/// View ▸ zoom, bound to the frontmost editor's canvas; disabled without a
/// photo on it.
private struct ZoomCommands: View {
    @FocusedValue(EditorModel.self) private var model

    var body: some View {
        let canvas = model?.canvas
        let hasPhoto = canvas?.imageFrame != nil
        Button("mac.menu.zoomToFit") { canvas?.fitToWindow() }
            .keyboardShortcut("0")
            .disabled(!hasPhoto)
        Button("mac.menu.actualSize") { canvas?.zoomToActualPixels() }
            .keyboardShortcut("1")
            .disabled(!hasPhoto)
        Button("mac.menu.zoomIn") { canvas?.zoomIn() }
            .keyboardShortcut("+")
            .disabled(canvas?.canZoomIn != true)
        Button("mac.menu.zoomOut") { canvas?.zoomOut() }
            .keyboardShortcut("-")
            .disabled(canvas?.canZoomOut != true)
    }
}

#if DEBUG
private struct DiagnosticsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("mac.diagnostics.title") { openWindow(id: "engine-diagnostics") }
    }
}
#endif
