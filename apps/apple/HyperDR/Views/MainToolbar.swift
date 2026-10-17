import SwiftUI

/// The window toolbar. It replaces the web header: the wordmark becomes the
/// window title, the theme toggle follows the system appearance, preferences
/// move to the Settings scene and the caption buttons are the system's.
/// Items that would overflow a narrow window fold into the toolbar's own
/// overflow menu.
struct MainToolbar: ToolbarContent {
    var workspace: Workspace
    @Binding var viewMode: ViewMode
    @Binding var showsInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("editor.open", systemImage: "folder") {}
                .help("mac.help.open")
            Button("lut.browse", systemImage: "swatchpalette") {}
                .help("lut.browse")
        }

        if workspace == .editing {
            ToolbarItem(placement: .principal) {
                Picker("editor.view", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    Button("edit.undo", systemImage: "arrow.uturn.backward") {}
                    Button("edit.redo", systemImage: "arrow.uturn.forward") {}
                        .disabled(true)
                }
                Button("workspace.versions", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {}
                    .help("workspace.versions")
            }

            ToolbarItem(placement: .primaryAction) {
                Button("editor.export", systemImage: "square.and.arrow.up") {}
                    .buttonStyle(.borderedProminent)
                    .help("mac.help.export")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("mac.toolbar.inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                .help(showsInspector ? "mac.toolbar.hideInspector" : "mac.toolbar.showInspector")
        }
    }
}
