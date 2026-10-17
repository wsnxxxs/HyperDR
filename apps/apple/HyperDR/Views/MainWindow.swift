import SwiftUI
import HyperDRDesign

/// The main window: the canvas with its status bar, and the inspector beside
/// them. The window's own toolbar carries the document actions, so the
/// title bar, traffic lights and full screen stay the system's.
///
/// Static layout only: nothing here talks to the engine yet.
struct MainWindow: View {
    var workspace: Workspace = .editing

    @State private var showsInspector = true
    @State private var viewMode = ViewMode.edited
    @State private var windowWidth: CGFloat = 1440

    var body: some View {
        CanvasView(workspace: workspace, viewMode: viewMode, padding: Layout.canvasPadding(forWindowWidth: windowWidth))
            // Under the canvas column only: an inset outside `.inspector` does
            // not reach the split's columns, and zoom and display state belong
            // to the photograph anyway.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(workspace: workspace)
            }
            .navigationTitle(workspace == .editing ? "DSC_0412.ARW" : "HyperDR")
            .navigationSubtitle(workspace == .editing ? "6000 × 4000 · RAW" : "")
            .toolbar { MainToolbar(workspace: workspace, viewMode: $viewMode, showsInspector: $showsInspector) }
            .inspector(isPresented: $showsInspector) {
                InspectorView(workspace: workspace)
                    .inspectorColumnWidth(Layout.inspectorWidth(forWindowWidth: windowWidth))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
            .frame(minWidth: 760, minHeight: 520)
            .background(Color.hdr.surfacePage)
            .foregroundStyle(Color.hdr.ink)
    }
}

#Preview("宽窗口 · 编辑", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow(workspace: .editing)
}

#Preview("宽窗口 · 未打开照片", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow(workspace: .empty)
}

#Preview("窄窗口 · 编辑", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow(workspace: .editing)
}

#Preview("宽窗口 · 深色", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow(workspace: .editing)
        .preferredColorScheme(.dark)
}
