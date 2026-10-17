import SwiftUI

/// The window toolbar. It replaces the web header: the wordmark becomes the
/// window title, the theme toggle follows the system appearance, preferences
/// move to the Settings scene and the caption buttons are the system's.
/// Items that would overflow a narrow window fold into the toolbar's own
/// overflow menu.
///
/// M1 opens photos and switches the original and edited views. The LUT
/// library, undo, export history, export and the comparison view arrive with
/// M2 / M3; until then they are present but disabled rather than wired to
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
            ToolbarItem(placement: .principal) {
                // Toggle buttons rather than a segmented Picker: in the
                // toolbar a Picker shows unavailable segments (and a wholly
                // disabled picker) exactly like available ones.
                ControlGroup {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Toggle(isOn: selects(mode)) { Text(mode.label) }
                            .disabled(!model.isAvailable(mode))
                    }
                }
                .toggleStyle(.button)
                .fixedSize()
                .accessibilityLabel("editor.view")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    Button("edit.undo", systemImage: "arrow.uturn.backward") {}
                    Button("edit.redo", systemImage: "arrow.uturn.forward") {}
                }
                .disabled(true)
                Button("workspace.versions", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {}
                    .help("workspace.versions")
                    .disabled(true)
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
            button.help("mac.help.open")
        }
    }

    /// On while `mode` is shown; turning it on shows it, turning the shown
    /// mode off does nothing (one mode is always shown).
    private func selects(_ mode: ViewMode) -> Binding<Bool> {
        Binding(get: { model.viewMode == mode }, set: { if $0 { model.viewMode = mode } })
    }
}
