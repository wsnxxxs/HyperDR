import SwiftUI

/// The editor's menu commands. They reach the frontmost editor window through
/// focused scene values, so they disable themselves when no editor window is
/// key.
///
/// The canvas's single-key shortcuts (F, +, −, C, hold Space, Esc) are
/// handled by `CanvasStage`, only while the canvas has focus; ⌘= zooms in
/// through `ZoomKeyMonitor`. PreviewCanvas itself never handles keyboard
/// input (batch 3 §12 Q9).
struct EditorCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            OpenCommand()
        }
        CommandGroup(after: .importExport) {
            FrameCommand()
        }
        CommandGroup(replacing: .undoRedo) {
            UndoCommands()
        }
        CommandGroup(before: .toolbar) {
            DisplayCommands()
            Divider()
            ZoomCommands()
            Divider()
        }
        #if DEBUG
        CommandMenu("mac.menu.developer") {
            DiagnosticsCommand()
            // Developer tools; not localized.
            Button { StressWindow.shared.show() } label: { Text(verbatim: "Inspector Stress (S12)") }
            Button { ControlsGalleryWindow.shared.show() } label: { Text(verbatim: "Inspector Controls") }
            Button { M2ComponentsGalleryWindow.shared.show() } label: { Text(verbatim: "Inspector, Scope and Canvas Components") }
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

/// File ▸ Frame… (⇧⌘B): the frame sheet for the frontmost editor's photo.
private struct FrameCommand: View {
    @FocusedValue(EditorModel.self) private var model
    @FocusedValue(EditorWindowState.self) private var window

    var body: some View {
        Button("frame.menu") { window?.isFraming = true }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(window == nil || model?.hasEditedFrame != true)
    }
}

/// Edit ▸ Undo and Redo (⌘Z, ⇧⌘Z). They go to the first responder's own
/// history when it is text, and to the photograph's edit history otherwise;
/// the titles name the step ("Undo Change Overall Brightness") and the items
/// follow the first responder through `UndoMenuState`.
private struct UndoCommands: View {
    @FocusedValue(EditorModel.self) private var model
    private let state = UndoMenuState.shared

    var body: some View {
        let _ = state.revision
        let responder = UndoRouting.firstResponder
        Button(UndoRouting.undoTitle(model: model, responder: responder)) {
            UndoRouting.undo(model: model, responder: UndoRouting.firstResponder)
        }
        .keyboardShortcut("z")
        .disabled(!UndoRouting.canUndo(model: model, responder: responder))
        Button(UndoRouting.redoTitle(model: model, responder: responder)) {
            UndoRouting.redo(model: model, responder: UndoRouting.firstResponder)
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!UndoRouting.canRedo(model: model, responder: responder))
    }
}

/// View ▸ the compare divider, the two zebras and the SDR preview. The
/// zebra items are the same two switches as the scope panel's. Compare has
/// no shortcut here: its key, C, belongs to the canvas.
private struct DisplayCommands: View {
    @FocusedValue(EditorModel.self) private var model

    var body: some View {
        Toggle("editor.compare", isOn: Binding(get: { model?.viewMode == .compare },
                                              set: { _ in model?.toggleCompare() }))
            .disabled(model?.isAvailable(.compare) != true)
        Toggle("view.zebraHighlights", isOn: Binding(get: { model?.showsHighlightZebra ?? false },
                                                     set: { model?.showsHighlightZebra = $0 }))
            .disabled(model?.hasEditedFrame != true)
        Toggle("view.zebraShadows", isOn: Binding(get: { model?.showsShadowZebra ?? false },
                                                  set: { model?.showsShadowZebra = $0 }))
            .disabled(model?.hasEditedFrame != true)
        Toggle("view.previewSDR", isOn: Binding(get: { model?.previewsAsSDR ?? false },
                                               set: { model?.previewsAsSDR = $0 }))
            .disabled(model?.hasEditedFrame != true)
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
