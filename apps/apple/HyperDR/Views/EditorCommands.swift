import SwiftUI

/// The editor's menu commands. They reach the frontmost editor window through
/// focused scene values, so they disable themselves when no editor window is
/// key.
///
/// F3 adds the View menu's zoom commands (⌘0, ⌘1, ⌘+, ⌘−). The canvas's
/// single-key shortcuts (F, +, −) are handled by the view around
/// PreviewCanvas, only while the canvas has focus; C and hold-Space belong to
/// M2. PreviewCanvas itself never handles keyboard input.
struct EditorCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            OpenCommand()
        }
        #if DEBUG
        CommandMenu("mac.menu.developer") {
            DiagnosticsCommand()
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

#if DEBUG
private struct DiagnosticsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("mac.diagnostics.title") { openWindow(id: "engine-diagnostics") }
    }
}
#endif
