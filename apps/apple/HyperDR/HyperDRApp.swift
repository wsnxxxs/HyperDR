import AppKit
import SwiftUI

@main struct HyperDRApp: App {
    @NSApplicationDelegateAdaptor(HyperDRApplicationDelegate.self) private var applicationDelegate
    @State private var editor: EditorModel
    @State private var dock: DockProgress?

    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

    init() {
        let isTesting = Self.isTesting
        if isTesting { NSApplication.shared.setActivationPolicy(.prohibited) } else { UndoMenuState.shared.install() }
        let editor = EditorModel(services: isTesting ? FakeEditorServices() : LiveEditorServices())
        _editor = State(initialValue: editor)
        applicationDelegate.editor = editor
        if !isTesting {
            ViewerSessionState.shared.scopeChannels = editor.preferences.value.histogramRGB ? .rgb : .luma
        }
    }

    var body: some Scene {
        Window("HyperDR", id: "editor") {
            MainWindow()
                .task {
                    if dock == nil, !Self.isTesting {
                        dock = DockProgress(model: editor)
                        dock?.start()
                    }
                    editor.launch()
                }
                .onOpenURL { editor.open([$0]) }
        }
        .environment(editor)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { EditorCommands() }

        Settings {
            SettingsView(model: editor)
        }

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
