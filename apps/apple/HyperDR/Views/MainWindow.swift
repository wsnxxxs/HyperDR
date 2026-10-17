import SwiftUI
import HyperDRDesign

/// The main window: the canvas with its status bar, and the inspector beside
/// them. The window's own toolbar carries the document actions, so the
/// title bar, traffic lights and full screen stay the system's.
///
/// Everything shown comes from the scene's `EditorModel` (batch 3 §3.4).
struct MainWindow: View {
    @Environment(EditorModel.self) private var environmentModel

    var body: some View {
        #if DEBUG
        EditorWindow(model: DebugScenario.model ?? environmentModel)
        #else
        EditorWindow(model: environmentModel)
        #endif
    }
}

/// Window-scoped UI state the menu commands reach through the focused scene.
@MainActor @Observable final class EditorWindowState {
    /// Whether the open panel is showing; the toolbar, the empty canvas and
    /// File ▸ Open… all set it.
    var isImporting = false
}

private struct EditorWindow: View {
    let model: EditorModel

    @State private var window = EditorWindowState()
    @State private var showsInspector = true
    @State private var windowWidth: CGFloat = 1440

    var body: some View {
        CanvasView(model: model, window: window, padding: Layout.canvasPadding(forWindowWidth: windowWidth))
            // Under the canvas column only: an inset outside `.inspector` does
            // not reach the split's columns, and zoom and display state belong
            // to the photograph anyway.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(model: model)
            }
            .navigationTitle(model.document?.name ?? "HyperDR")
            .navigationSubtitle(subtitle)
            .toolbar { MainToolbar(model: model, window: window, showsInspector: $showsInspector) }
            .inspector(isPresented: $showsInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(Layout.inspectorWidth(forWindowWidth: windowWidth))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
            .frame(minWidth: 760, minHeight: 520)
            .background(Color.hdr.surfacePage)
            .foregroundStyle(Color.hdr.ink)
            .fileImporter(isPresented: Bindable(window).isImporting,
                          allowedContentTypes: model.openableContentTypes) { result in
                // Cancelling the panel is not an error; a failure to resolve
                // the chosen file surfaces when the model tries to open it.
                if case .success(let url) = result { model.open([url]) }
            }
            .alert(alertTitle, isPresented: alertPresented, presenting: model.alert) { _ in
                // No actions: the system supplies a localized OK.
            } message: { error in
                Text(verbatim: ErrorText(error).body)
            }
            .focusedSceneValue(model)
            .focusedSceneValue(window)
    }

    /// "6000 × 4000 · RAW"; only the format until the first frame names the size.
    private var subtitle: String {
        guard let document = model.document else { return "" }
        guard let size = document.pixelSize else { return document.formatLabel }
        return "\(size.width) × \(size.height) · \(document.formatLabel)"
    }

    private var alertTitle: Text {
        guard let alert = model.alert else { return Text(verbatim: "") }
        return Text(ErrorText(alert).title)
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.dismissAlert() } })
    }
}

extension EngineStatus {
    /// Why the engine cannot be used, or nil while it is starting or ready.
    var failure: UserFacingError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// Each scenario in a wide light window and a narrow dark one, so every state
// is seen at both widths and in both appearances.

#Preview("Empty · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.empty))
}
#Preview("Opening · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.opening))
}
#Preview("First frame rendering · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.firstFrameRendering))
}
#Preview("Editing, HDR display · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.editingHDRDisplay))
}
#Preview("Editing, SDR display · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.editingSDRDisplay))
}
#Preview("Refreshing · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.refreshing))
}
#Preview("Preview failed, frame kept · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.previewFailedKeepsFrame))
}
#Preview("First frame failed · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.firstFrameFailed))
}
#Preview("Open failed · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.openFailed))
}
#Preview("Engine failed · wide", traits: .fixedLayout(width: 1440, height: 900)) {
    MainWindow().environment(EditorModel.preview(.engineFailed))
}

#Preview("Empty · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.empty)).preferredColorScheme(.dark)
}
#Preview("Opening · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.opening)).preferredColorScheme(.dark)
}
#Preview("First frame rendering · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.firstFrameRendering)).preferredColorScheme(.dark)
}
#Preview("Editing, HDR display · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.editingHDRDisplay)).preferredColorScheme(.dark)
}
#Preview("Editing, SDR display · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.editingSDRDisplay)).preferredColorScheme(.dark)
}
#Preview("Refreshing · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.refreshing)).preferredColorScheme(.dark)
}
#Preview("Preview failed, frame kept · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.previewFailedKeepsFrame)).preferredColorScheme(.dark)
}
#Preview("First frame failed · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.firstFrameFailed)).preferredColorScheme(.dark)
}
#Preview("Open failed · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.openFailed)).preferredColorScheme(.dark)
}
#Preview("Engine failed · narrow dark", traits: .fixedLayout(width: 820, height: 640)) {
    MainWindow().environment(EditorModel.preview(.engineFailed)).preferredColorScheme(.dark)
}
