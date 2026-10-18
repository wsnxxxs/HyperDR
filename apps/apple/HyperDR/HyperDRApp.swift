import AppKit
import SwiftUI

@main struct HyperDRApp: App {
    @State private var editor: EditorModel

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        if isTesting { NSApplication.shared.setActivationPolicy(.prohibited) }
        _editor = State(initialValue: EditorModel(services: isTesting
            ? FakeEditorServices() : LiveEditorServices()))
    }

    var body: some Scene {
        Window("HyperDR", id: "editor") {
            MainWindow()
                .task { editor.launch() }
                .onOpenURL { editor.open([$0]) }
        }
        .environment(editor)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { EditorCommands() }

        // A developer tool, opened from the Developer menu; release builds
        // have neither.
        #if DEBUG
        Window("mac.diagnostics.title", id: "engine-diagnostics") {
            AppContentView()
        }
        .defaultSize(width: 1080, height: 650)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
}
