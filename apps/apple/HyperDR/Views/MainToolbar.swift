import SwiftUI
import HyperDRDesign

/// The canvas column's part of the window toolbar. It replaces the web
/// header: the wordmark becomes the window title, the theme toggle follows the
/// system appearance, preferences move to the Settings scene and the caption
/// buttons are the system's. Items that would overflow a narrow window fold
/// into the toolbar's own overflow menu.
///
/// Open and the LUT library lead; undo and redo, then the original / edited /
/// compare views, end the column at the canvas's top right. The rest
/// (`DocumentToolbar`) stands above the inspector; the system keeps it in the
/// window's corner while the inspector is hidden.
struct MainToolbar: ToolbarContent {
    let model: EditorModel
    let window: EditorWindowState
    /// A narrow window's column has no room for the three views and undo
    /// and redo, and the system would fold some of the views into its
    /// overflow menu: the views become one pull-down, and undo and redo stay
    /// in the Edit menu and on ⌘Z and ⇧⌘Z.
    var isNarrow = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            openButton
            Button("lut.browse", systemImage: "swatchpalette") { window.showsLUTLibrary = true }
                .help("lut.browse")
        }

        if model.workspace == .editing {
            if !isNarrow {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("edit.undo", systemImage: "arrow.uturn.backward") { model.undo() }
                        .help("edit.undo")
                        .disabled(!model.canUndo)
                    Button("edit.redo", systemImage: "arrow.uturn.forward") { model.redo() }
                        .help("edit.redo")
                        .disabled(!model.canRedo)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            // Buttons rather than a segmented Picker or toggles: in the toolbar
            // a Picker shows unavailable segments (and a wholly disabled
            // picker) exactly like available ones, and toggle buttons (alone
            // or in a ControlGroup) have no accessibility name.
            if isNarrow {
                ToolbarItem(placement: .primaryAction) {
                    ViewModeMenu(model: model)
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        ViewModeButton(mode: mode, model: model)
                    }
                }
            }
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

/// Above the inspector: export history, the frame, export and the
/// inspector's own toggle. Export's button carries the export's progress and
/// opens the panel; every other reason it cannot start is told by the panel
/// itself.
struct DocumentToolbar: ToolbarContent {
    let model: EditorModel
    let window: EditorWindowState
    @Binding var showsInspector: Bool
    var body: some ToolbarContent {
        // Over the inspector the items would start at its leading edge.
        ToolbarSpacer(.flexible)
        if model.workspace == .editing {
            ToolbarItemGroup(placement: .primaryAction) {
                HistoryButton(model: model, window: window)
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
}

/// One of Original / Edited / Compare: a selected segment's capsule while
/// shown (not the accent fill, which belongs to Export), dimmed while
/// unavailable, and announced as shown.
private struct ViewModeButton: View {
    let mode: ViewMode
    let model: EditorModel

    var body: some View {
        let selected = model.viewMode == mode
        let available = model.isAvailable(mode)
        Button { model.viewMode = mode } label: {
            Text(mode.label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.hdr.selectedInk : available ? Color.hdr.ink : Color.hdr.inkDisabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(selected ? Color.hdr.selectedBackground : Color.clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // The trait does not reach AppKit from a toolbar item; say it.
        .accessibilityValue(selected ? Text("mac.toolbar.shown") : Text(verbatim: ""))
    }
}

/// The views in a narrow window: the one shown, opening a menu of all three
/// with the shown one checked and the unavailable ones off.
private struct ViewModeMenu: View {
    let model: EditorModel

    var body: some View {
        Menu {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Toggle(mode.label, isOn: Binding(get: { model.viewMode == mode },
                                                 set: { if $0 { model.viewMode = mode } }))
                    .disabled(!model.isAvailable(mode))
            }
        } label: {
            Text(model.viewMode.label)
        }
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
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                button(.exporting(fraction: ExportPresentation.percent(
                    estimate: model.export.estimate(at: model.now()), isDone: false)))
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
