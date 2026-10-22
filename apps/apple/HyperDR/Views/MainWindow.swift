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
    /// The panel was opened to find a photo's moved file, not to open a photo.
    var isLocating = false
    /// Asks for the photo's file again (the open panel, answered by
    /// `locateSource` instead of an open).
    func locateSource() { isLocating = true; isImporting = true }
    /// The panel closed, with a choice or without one (a cancelled panel never
    /// calls the completion handler): the next one is an ordinary open again.
    func importPanelEnded() { isLocating = false }
    /// Whether the frame sheet is showing; the toolbar and File ▸ Frame… set it.
    var isFraming = false
    /// The export panel, export history and LUT library sheets; the
    /// toolbar, the menu and the inspector's cards open them.
    var showsExport = false
    var showsHistory = false
    var showsLUTLibrary = false
    /// Whether the lock is flashing: the user touched something an export
    /// has locked (M3 §5.2). It falls back by itself after 0.6 s.
    private(set) var isEmphasizingLock = false
    @ObservationIgnored private var emphasisTask: Task<Void, Never>?

    func emphasizeLock() {
        emphasisTask?.cancel()
        isEmphasizingLock = true
        emphasisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { self?.isEmphasizingLock = false }
        }
    }

    /// Opens the export panel; with the export running it shows the progress.
    func openExport() { showsExport = true }

    /// "Change…" on the export panel's Frame row: the frame sheet takes the
    /// export panel's place, and the export panel comes back when it closes,
    /// so the user ends up where they were. Two sheets of one window cannot
    /// be up together, so each is presented from the other's `onDismiss`, when
    /// it has really gone, and only if the window is still in the state the
    /// hand-over assumed: nothing else open, a photograph, no question about
    /// switching it waiting (a sheet would hide that question, M3 §5.6).
    private(set) var returnsToExport = false
    @ObservationIgnored private var framesWhenExportLeaves = false

    func changeFrameFromExport() {
        guard !isFraming, showsExport else { return }
        returnsToExport = true
        framesWhenExportLeaves = true
        showsExport = false
    }

    /// The export panel has gone (any way): on to the frame sheet if it was asked for.
    func exportSheetDismissed(hasPhoto: Bool, isAskingToSwitch: Bool) {
        guard framesWhenExportLeaves else { return }
        framesWhenExportLeaves = false
        guard canHandOver(hasPhoto: hasPhoto, isAskingToSwitch: isAskingToSwitch) else { returnsToExport = false; return }
        isFraming = true
    }

    /// The frame sheet has gone: back to the export panel if it came from there.
    func frameSheetDismissed(hasPhoto: Bool, isAskingToSwitch: Bool) {
        guard returnsToExport else { return }
        returnsToExport = false
        guard canHandOver(hasPhoto: hasPhoto, isAskingToSwitch: isAskingToSwitch) else { return }
        showsExport = true
    }

    private func canHandOver(hasPhoto: Bool, isAskingToSwitch: Bool) -> Bool {
        !showsExport && !isFraming && !showsHistory && !showsLUTLibrary && hasPhoto && !isAskingToSwitch
    }
}

/// The open panel: File ▸ Open…, and the banner's "Locate Photo…" (which
/// answers with `locateSource` instead of an open).
private struct PhotoImporter: ViewModifier {
    let model: EditorModel
    let window: EditorWindowState

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: Bindable(window).isImporting,
                             allowedContentTypes: model.openableContentTypes,
                             allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { break }
                if window.isLocating { model.locateSource(url) } else { model.open([url]) }
            case .failure(let error):
                // The model ignores a cancelled panel.
                if !window.isLocating { model.report(openFailure: error) }
            }
            window.importPanelEnded()
        } onCancellation: {
            window.importPanelEnded()
        }
    }
}

private struct EditorWindow: View {
    let model: EditorModel

    @State private var window = EditorWindowState()
    @State private var showsInspector = true
    @State private var windowWidth: CGFloat = 1440
    @State private var zoomKey = ZoomKeyMonitor()
    @State private var openCancelKey = OpenCancelKeyMonitor()
    @Environment(\.locale) private var locale

    var body: some View {
        CanvasView(model: model, window: window, padding: Layout.canvasPadding(forWindowWidth: windowWidth),
                   showsInspector: showsInspector)
            // Under the canvas column only: an inset outside `.inspector` does
            // not reach the split's columns, and zoom and display state belong
            // to the photograph anyway.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(model: model)
            }
            .navigationTitle(model.document?.name ?? "HyperDR")
            .navigationSubtitle(subtitle)
            .toolbar {
                MainToolbar(model: model, window: window, isNarrow: windowWidth < Layout.narrowBreakpoint)
            }
            .inspector(isPresented: $showsInspector) {
                InspectorView(model: model, window: window)
                    .inspectorColumnWidth(Layout.inspectorWidth(forWindowWidth: windowWidth))
                    // Above the inspector's column, so the canvas column's
                    // items end at the canvas.
                    .toolbar { DocumentToolbar(model: model, window: window, showsInspector: $showsInspector) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
            .frame(minWidth: 760, minHeight: 520)
            .background(Color.hdr.surfacePage)
            .foregroundStyle(Color.hdr.ink)
            .modifier(PhotoImporter(model: model, window: window))
            .sheet(isPresented: Bindable(window).isFraming, onDismiss: {
                window.frameSheetDismissed(hasPhoto: model.document != nil, isAskingToSwitch: model.pendingPhotoSwitch != nil)
            }) {
                FrameSheet(model: model)
            }
            .sheet(isPresented: Bindable(window).showsExport, onDismiss: {
                window.exportSheetDismissed(hasPhoto: model.document != nil, isAskingToSwitch: model.pendingPhotoSwitch != nil)
            }) {
                ExportSheet(model: model, window: window)
            }
            .sheet(isPresented: Bindable(window).showsHistory) {
                ExportHistorySheet(model: model)
            }
            .onChange(of: LookPreviewInputs(editor: model.editor, looks: model.lookPreviewLooks), initial: true) { _, inputs in
                model.lookPreviews.update(model.editor, looks: inputs.looks)
            }
            .sheet(isPresented: Bindable(window).showsLUTLibrary) {
                LUTLibrarySheet(model: model)
                    .environment(\.lookPickerShown, model.lookPreviews.shown)
            }
            // A sheet would hide the question: close it first.
            .onChange(of: model.pendingPhotoSwitch != nil) { _, asking in
                if asking { window.showsExport = false; window.showsHistory = false; window.showsLUTLibrary = false }
            }
            .background { Color.clear.photoSwitchAlert(model: model) }
            .alert(alertTitle, isPresented: alertPresented, presenting: model.alert) { _ in
                // No actions: the system supplies a localized OK.
            } message: { error in
                Text(verbatim: ErrorText(error).body)
            }
            .onPasteCommand(of: PasteImport.types) { PasteImport.handle($0, model: model) }
            .focusedSceneValue(model)
            .focusedSceneValue(window)
            .environment(ViewerSessionState.shared)
            // ⌘= zooms in while this window is key (M2-Q).
            .background(WindowReader { found in
                if let found {
                    zoomKey.install(window: found, canvas: model.canvas)
                    openCancelKey.install(window: found, model: model)
                } else { zoomKey.remove(); openCancelKey.remove() }
            })
            .onDisappear { zoomKey.remove(); openCancelKey.remove() }
            #if DEBUG
            .task {
                StressWindow.runIfRequested()
                ControlsGalleryWindow.showIfRequested()
            }
            #endif
    }

    /// "6000 × 4000 · RAW · Not exported"; only the format until the first
    /// frame names the size, and the edit's state once there is a frame.
    private var subtitle: String {
        guard let document = model.document else { return "" }
        var parts = [document.formatLabel]
        if let size = document.pixelSize { parts.insert("\(size.width) × \(size.height)", at: 0) }
        if let key = ExportPresentation.documentStatusKey(model.documentStatus, isExporting: model.export.isInFlight) {
            parts.append(AppStrings.string(key, locale: locale))
        }
        return parts.joined(separator: " · ")
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
