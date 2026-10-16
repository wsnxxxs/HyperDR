import SwiftUI

@main struct HyperDRApp: App {
    var body: some Scene {
        WindowGroup("HyperDR") {
            MainWindow()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)

        Window("引擎诊断", id: "engine-diagnostics") {
            AppContentView()
        }
        .defaultSize(width: 1080, height: 650)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
