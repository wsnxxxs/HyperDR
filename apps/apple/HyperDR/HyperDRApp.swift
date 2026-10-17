import SwiftUI

@main struct HyperDRApp: App {
    @State private var editor = EditorModel()

    var body: some Scene {
        Window("HyperDR", id: "editor") {
            MainWindow()
        }
        .environment(editor)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { EditorCommands() }

        Window("引擎诊断", id: "engine-diagnostics") {
            AppContentView()
        }
        .defaultSize(width: 1080, height: 650)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
