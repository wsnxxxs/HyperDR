import SwiftUI
import HyperDRDesign

/// The window toolbar. It replaces the web header: the wordmark becomes the
/// window title, the theme toggle follows the system appearance, preferences
/// move to the Settings scene and the caption buttons are the system's.
/// Items that would overflow a narrow window fold into the toolbar's own
/// overflow menu.
///
/// Open, the LUT library, the original / edited / compare views, undo and
/// redo, export history, the frame, export and the inspector. Export's
/// button carries the export's progress and opens the panel; every other
/// reason it cannot start is told by the panel itself.
struct MainToolbar: ToolbarContent {
    let model: EditorModel
    let window: EditorWindowState
    @Binding var showsInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            openButton
            Button("lut.browse", systemImage: "swatchpalette") { window.showsLUTLibrary = true }
                .help("lut.browse")
        }

        if model.workspace == .editing {
            // Buttons rather than a segmented Picker or toggles: in the toolbar
            // a Picker shows unavailable segments (and a wholly disabled
            // picker) exactly like available ones, and toggle buttons (alone
            // or in a ControlGroup) have no accessibility name.
            ToolbarItemGroup(placement: .principal) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    ViewModeButton(mode: mode, model: model)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button("edit.undo", systemImage: "arrow.uturn.backward") { model.undo() }
                    .help("edit.undo")
                    .disabled(!model.canUndo)
                Button("edit.redo", systemImage: "arrow.uturn.forward") { model.redo() }
                    .help("edit.redo")
                    .disabled(!model.canRedo)
                HistoryButton(model: model, window: window)
            }

            ToolbarItem(placement: .primaryAction) {
                Button("frame.toolbar", systemImage: "photo.artframe") { window.isFraming = true }
                    .help("frame.toolbar.help")
                    .disabled(!model.hasEditedFrame)
            }

            ToolbarItem(placement: .primaryAction) {
                ExportButton(model: model, window: window)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("mac.toolbar.inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                .help(showsInspector ? "mac.toolbar.hideInspector" : "mac.toolbar.showInspector")
        }
    }

    @ViewBuilder private var openButton: some View {
        let button = Button("editor.open", systemImage: "folder") { window.isImporting = true }
        if let failure = model.engine.failure {
            // The disabled button says why, in the alert's own words.
            button.disabled(true).help(Text(ErrorText(failure).title))
        } else {
            button.disabled(!model.allowsOpenCommand).help("mac.help.open")
        }
    }

}

/// One of Original / Edited / Compare: an accent-filled capsule while shown,
/// dimmed while unavailable, and announced as shown.
private struct ViewModeButton: View {
    let mode: ViewMode
    let model: EditorModel

    var body: some View {
        let selected = model.viewMode == mode
        let available = model.isAvailable(mode)
        Button { model.viewMode = mode } label: {
            Text(mode.label)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.hdr.accentInk : available ? Color.hdr.ink : Color.hdr.inkDisabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? Color.hdr.accentFill : Color.clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // The trait does not reach AppKit from a toolbar item; say it.
        .accessibilityValue(selected ? Text("mac.toolbar.shown") : Text(verbatim: ""))
    }
}

/// Export history: the clock, with the number of versions of this photo.
private struct HistoryButton: View {
    let model: EditorModel
    let window: EditorWindowState

    var body: some View {
        Button { window.showsHistory = true } label: {
            Label("workspace.versions", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        }
        .help("workspace.versions")
        .overlay(alignment: .topTrailing) {
            if !model.exportVersions.isEmpty {
                Text(verbatim: model.exportVersions.count.formatted())
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.hdr.accentInk)
                    .padding(.horizontal, 4)
                    .background(Color.hdr.accentFill, in: .capsule)
                    .offset(x: 4, y: -2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(Text("history.versions \(model.exportVersions.count.formatted())"))
    }
}

/// The export button (M3 §2.1): its title follows the chosen format, while
/// an export runs it carries the progress and opens the panel's progress
/// view, and without a photo it is off with the reason.
struct ExportButton: View {
    let model: EditorModel
    let window: EditorWindowState

    var body: some View {
        if model.export.isInFlight {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                button(.exporting(fraction: ExportPresentation.percent(
                    estimate: model.export.estimate(at: context.date), isDone: false)))
            }
        } else if model.document == nil {
            button(.disabled(title: Text("editor.export"), reason: Text("export.blocker.noPhoto")))
        } else {
            button(.idle(title: Text(LocalizedStringKey(ExportPresentation.toolbarTitleKey(encoding: model.export.encodingID)))))
        }
    }

    private func button(_ state: ExportButtonState) -> some View {
        ExportToolbarButton(state: state) { window.openExport() }
            .help(model.export.isInFlight ? Text("export.menu.showProgress") : Text("mac.help.export"))
    }
}
