import SwiftUI
import HyperDRDesign

/// The window toolbar. It replaces the web header: the wordmark becomes the
/// window title, the theme toggle follows the system appearance, preferences
/// move to the Settings scene and the caption buttons are the system's.
/// Items that would overflow a narrow window fold into the toolbar's own
/// overflow menu.
///
/// Open, the original / edited / compare views, undo and redo, the frame and
/// the inspector are live. The LUT library, export history and export arrive
/// with M3; until then they are present but disabled rather than wired to
/// actions that do nothing.
struct MainToolbar: ToolbarContent {
    let model: EditorModel
    let window: EditorWindowState
    @Binding var showsInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            openButton
            Button("lut.browse", systemImage: "swatchpalette") {}
                .help("lut.browse")
                .disabled(true)
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
                Button("workspace.versions", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {}
                    .help("workspace.versions")
                    .disabled(true)
            }

            ToolbarItem(placement: .primaryAction) {
                Button("frame.toolbar", systemImage: "photo.artframe") { window.isFraming = true }
                    .help("frame.toolbar.help")
                    .disabled(!model.hasEditedFrame)
            }

            ToolbarItem(placement: .primaryAction) {
                // Prominent again once M3 enables it: a disabled prominent
                // button still reads as the window's main action.
                Button("editor.export", systemImage: "square.and.arrow.up") {}
                    .help("mac.help.export")
                    .disabled(true)
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
