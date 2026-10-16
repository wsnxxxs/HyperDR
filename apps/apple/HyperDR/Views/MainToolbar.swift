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
            Button("打开照片", systemImage: "folder") {}
                .help("打开照片（⌘O）")
            Button("LUT 库", systemImage: "swatchpalette") {}
                .help("LUT 库")
        }

        if workspace == .editing {
            ToolbarItem(placement: .principal) {
                Picker("预览方式", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    Button("撤销", systemImage: "arrow.uturn.backward") {}
                    Button("重做", systemImage: "arrow.uturn.forward") {}
                        .disabled(true)
                }
                Button("导出记录", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {}
                    .help("导出记录")
            }

            ToolbarItem(placement: .primaryAction) {
                Button("导出", systemImage: "square.and.arrow.up") {}
                    .buttonStyle(.borderedProminent)
                    .help("导出照片（⌘E）")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("检查器", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                .help(showsInspector ? "隐藏检查器" : "显示检查器")
        }
    }
}
