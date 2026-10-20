import HyperDRDesign
import HyperDRRecipe
import HyperDRRender
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The iPhone and iPad editor (P7-2b): a photo from the library or Files,
/// rendered by HyperDRRender through the shared `RecipeEditor`, on the EDR
/// canvas with the adjustment controls laid out by `AdjustmentWorkspace`.
/// Entry points follow p7-adjustments §5.5: an empty state with a large Choose
/// Photo button and an Open from Files text button; with a photo open, Photos
/// leads the top bar, undo and redo follow, and Open from Files and Reset All
/// sit in the More menu. Undo steps go to the scene's undo manager, so the
/// three-finger swipe and ⌘Z work too.
struct PhotoCanvasScreen: View {
    /// One open request; a newer one cancels the load of the previous.
    private struct Request: Equatable {
        enum Source: Equatable { case library(PhotosPickerItem), file(URL) }
        let id = UUID()
        let source: Source
    }

    @State private var editor: RecipeEditor?
    @State private var unavailable = false
    @State private var selection: PhotosPickerItem?
    @State private var request: Request?
    @State private var importingFile = false
    /// The copy the editor has open.
    @State private var photo: ImportedPhoto?
    @State private var loading = false
    @State private var failed = false
    /// A failure over an open photo, shown for a moment.
    @State private var notice: LocalizedStringKey?
    @State private var headroom = HeadroomSnapshot()
    @State private var holdingOriginal = false
    @State private var confirmingReset = false
    @State private var showingAdjustments = false
    @Environment(\.undoManager) private var undoManager
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let editor, editor.source != nil {
                    workspace(editor)
                } else if loading {
                    ProgressView().tint(.white)
                } else {
                    emptyState
                }
            }
            .toolbar { if let editor, editor.source != nil { toolbar(editor) } }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            // Before the canvas exists, the screen bounds the first decode.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard let editor, editor.canvasPixelSize == nil else { return }
                editor.canvasPixelSize = PixelSize(width: Int(size.width * displayScale),
                                                   height: Int(size.height * displayScale))
            }
        }
        .onChange(of: selection) { _, item in
            // Cleared once used, so picking the same photo again (after a
            // file, or after a failed load) is a new request too.
            guard let item else { return }
            request = Request(source: .library(item))
            selection = nil
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { request = Request(source: .file(url)) }
        }
        .task { makeEditor() }
        .task(id: request?.id) { await load(request?.source) }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { editor?.attach(undoManager: undoManager) }
        .confirmationDialog(Text("ios.adjust.resetAll.confirm"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(role: .destructive) { editor?.resetAll() } label: { AdjustmentText.command(.resetAll) }
        }
        #if DEBUG
        .fullScreenCover(isPresented: $showingAdjustments) { AdjustmentsDebugScreen() }
        #endif
    }

    // MARK: - Editor

    private func makeEditor() {
        guard editor == nil, !unavailable else { return }
        guard let session = try? RenderSession() else {
            unavailable = true
            return
        }
        let editor = RecipeEditor(renderer: session)
        editor.undo.actionName = Self.undoName
        editor.attach(undoManager: undoManager)
        self.editor = editor
    }

    private static func undoName(_ edit: RecipeEdit) -> String {
        switch edit {
        case .parameter(let id): return Adjustments.declaration(id).map { AdjustmentText.undoName($0) } ?? id
        case .resetGroup(let group): return AdjustmentText.undoName(.group(group))
        case .resetAll: return AdjustmentText.undoName(.all)
        }
    }

    private func panel(_ editor: RecipeEditor) -> AdjustmentPanel {
        AdjustmentPanel(context: AdjustmentContext(
            sourceValues: editor.source?.sourceValues ?? [:], automaticValues: editor.automaticValues,
            capabilities: editor.source?.capabilities ?? [], unavailableOptions: editor.unavailableOptions))
    }

    private func workspace(_ editor: RecipeEditor) -> some View {
        AdjustmentWorkspace(recipe: Binding(get: { editor.recipe }, set: { editor.setRecipe($0) }),
                            panel: panel(editor),
                            onEditingChanged: { editor.editingChanged($0, $1) },
                            onReset: { reset in
                                switch reset {
                                case .group(let group): editor.resetGroup(group)
                                case .all: editor.resetAll()
                                }
                            }) {
            canvas(editor)
        }
    }

    private func canvas(_ editor: RecipeEditor) -> some View {
        ZStack(alignment: .top) {
            EDRCanvas(content: canvasContent(editor),
                      onHeadroom: { headroom = $0 },
                      onDrawableSize: { editor.canvasPixelSize = $0 },
                      onHoldOriginal: { holdingOriginal = $0 },
                      onError: { _ in notice = "ios.error.load" })
                .ignoresSafeArea(edges: .top)
            VStack(spacing: Space.s2) {
                if holdingOriginal, editor.originalFrame != nil { capsule(Text("ios.canvas.original")) }
                if editor.aiStatus == .computing { capsule(Text("ios.ai.computing")) }
                if case .failed = editor.aiStatus { capsule(Text("ios.ai.failed")) }
                if let notice { capsule(Text(notice)) }
                if loading { ProgressView().tint(.white) }
            }
            .padding(.top, Space.s2)
        }
        .overlay(alignment: .bottom) { headroomReadout }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }

    private func canvasContent(_ editor: RecipeEditor) -> EDRCanvasUIView.Content? {
        guard let frame = editor.frame, let source = editor.frameSource else { return nil }
        // Until the new photo's first frame arrives the previous one stays, at its own size.
        let size = source.pixelSize
        let original = editor.originalFrame.flatMap { $0.request.sourceID == frame.request.sourceID ? $0 : nil }
        return EDRCanvasUIView.Content(edited: DisplayPair(frame.display),
                                       original: original.map { DisplayPair($0.display) },
                                       showsOriginal: holdingOriginal,
                                       imageSize: CGSize(width: size.width, height: size.height))
    }

    private func capsule(_ text: Text) -> some View {
        text
            .font(.system(size: TypeScale.Size.caption, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s1)
            .background(.ultraThinMaterial, in: .capsule)
    }

    // MARK: - Chrome

    private var emptyState: some View {
        VStack(spacing: Space.s4) {
            Text(failed || unavailable ? LocalizedStringKey("ios.error.load") : LocalizedStringKey("ios.empty.message"))
                .font(.system(size: TypeScale.Size.body))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Label("ios.picker.choose", systemImage: "photo.on.rectangle")
                    .font(.system(size: TypeScale.Size.title, weight: .semibold))
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s2)
            }
            .buttonStyle(.glassProminent)
            .disabled(unavailable)
            Button("ios.file.open") { importingFile = true }
                .buttonStyle(.borderless)
                .tint(.white)
                .disabled(unavailable)
            #if DEBUG
            Button { showingAdjustments = true } label: { Text(verbatim: "Adjustment controls (debug)") }
                .buttonStyle(.borderless)
                .tint(.white.opacity(0.6))
            #endif
        }
        .padding(Space.s6)
    }

    @ToolbarContentBuilder private func toolbar(_ editor: RecipeEditor) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Text("ios.toolbar.photos")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Read with the recipe, so the buttons follow every step.
            let _ = editor.recipe
            Button {
                editor.commitDrag()
                undoManager?.undo()
            } label: {
                Label("ios.toolbar.undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(undoManager?.canUndo != true)
            Button {
                editor.commitDrag()
                undoManager?.redo()
            } label: {
                Label("ios.toolbar.redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(undoManager?.canRedo != true)
            Menu {
                Button("ios.file.openMenu", systemImage: "folder") { importingFile = true }
                Button(role: .destructive) { confirmingReset = true } label: {
                    Label { AdjustmentText.command(.resetAll) } icon: { Image(systemName: "arrow.counterclockwise") }
                }
                #if DEBUG
                Button { showingAdjustments = true } label: {
                    Label { Text(verbatim: "Adjustment controls (debug)") } icon: { Image(systemName: "slider.horizontal.3") }
                }
                #endif
            } label: {
                Label("ios.toolbar.more", systemImage: "ellipsis")
            }
        }
    }

    private var headroomReadout: some View {
        Text("ios.display.edr \(Self.headroom(headroom.current)) \(Self.headroom(headroom.potential))")
            .font(.system(size: TypeScale.Size.caption).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .padding(.bottom, Space.s2)
            .allowsHitTesting(false)
    }

    private static func headroom(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(1))) + "×"
    }

    // MARK: - Opening

    /// Copies the original into our own file (library: as a file, `.current`
    /// keeps HEIC, DNG and gain maps; Files: inside its security scope) and
    /// opens it. The previous photo stays on screen until the new one is
    /// ready, and its copy is removed once the new one is open.
    private func load(_ source: Request.Source?) async {
        guard let source, let editor else { return }
        loading = true
        // A newer request has started its own load; leave its spinner alone.
        defer { if !Task.isCancelled { loading = false } }
        var imported: ImportedPhoto?
        do {
            switch source {
            case .library(let item):
                imported = try await item.loadTransferable(type: ImportedPhoto.self)
            case .file(let url):
                imported = try await Task.detached(priority: .userInitiated) { try ImportedPhoto.copyFromFiles(url) }.value
            }
            guard let imported else { throw CocoaError(.fileReadUnknown) }
            try await editor.open(imported.url)
            photo?.discard()
            photo = imported
            failed = false
        } catch {
            imported?.discard()
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if editor.source == nil { failed = true } else { notice = "ios.error.load" }
        }
    }
}
