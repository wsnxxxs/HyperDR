import HyperDRDesign
import HyperDRRecipe
import HyperDRRender
import PhotosUI
import SwiftUI

/// The editor, over the library while a photo is open: the EDR canvas, the
/// controls laid out by `EditorLayout`, and a toolbar of Liquid Glass
/// buttons laid out as in Photos: close, undo and redo lead; More (with the
/// comparison) and Export, the one prominent button, trail. Undo steps go to
/// the scene's undo manager, so the three-finger swipe and ⌘Z work too.
///
/// Comparison follows §5.4: holding the canvas shows the original, and More
/// switches between Adjusted, Original and Split. Zoomed in, the
/// editor adds full-size detail tiles; while a parameter with a mask is
/// dragged, its mask is tinted over the edit. The Frame pane shows the
/// export's frame around the photo.
struct EditorScreen: View {
    let session: EditingSession
    let editor: RecipeEditor

    @State private var pane = EditorPane.group(.hdr)
    @State private var comparison = Comparison.edited
    @State private var splitRatio = 0.5
    @State private var holdingOriginal = false
    @State private var transform: CanvasTransform?
    @State private var windowSize = CGSize.zero
    @State private var showsInspector = true
    @State private var showingExport = false
    @State private var showingLUTs = false
    @State private var importingLUTs = false
    @State private var importingFile = false
    @State private var pickingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var confirmingReset = false
    @State private var confirmingClose = false
    @Environment(\.undoManager) private var undoManager
    @Environment(\.displayScale) private var displayScale

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var layout: EditorLayout { EditorLayout.layout(for: windowSize, isPad: isPad) }

    var body: some View {
        NavigationStack {
            workspace
                .background(Color.black.ignoresSafeArea())
                // The photo importer is on the stack; this one is on its content,
                // since one view takes one importer.
                .fileImporter(isPresented: $importingLUTs, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                    guard case .success(let urls) = result else { return }
                    Task {
                        await session.exports.luts.importLUTs(urls, into: editor)
                        if !session.exports.luts.failures.isEmpty { showingLUTs = true }
                    }
                }
                .toolbar { toolbar }
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle(isPad ? Text(verbatim: session.photoName ?? "") : Text(verbatim: ""))
                .navigationSubtitle(isPad ? subtitle : Text(verbatim: ""))
                .inspector(isPresented: Binding(get: { layout == .inspector && showsInspector },
                                                set: { if layout == .inspector { showsInspector = $0 } })) {
                    inspector
                        .inspectorColumnWidth(min: 320, ideal: 340, max: 420)
                }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            windowSize = size
            // Before the canvas exists, the window bounds the first decode.
            guard editor.canvasPixelSize == nil else { return }
            editor.canvasPixelSize = PixelSize(width: Int(size.width * displayScale), height: Int(size.height * displayScale))
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { session.open(.file(url)) }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $picked, matching: .images, preferredItemEncoding: .current)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            session.open(.library(item))
        }
        .onChange(of: viewport, initial: true) { _, viewport in editor.setViewport(viewport) }
        .onChange(of: undoManager.map(ObjectIdentifier.init), initial: true) { editor.attach(undoManager: undoManager) }
        .onChange(of: pane, initial: true) { _, pane in
            // The frame is drawn from the whole photo: leave zoom and split behind.
            if pane == .frame || pane == .crop, comparison != .edited { comparison = .edited }
            // The crop is edited on the whole photo, rendered once; leaving renders it cropped.
            editor.isEditingCrop = pane == .crop
        }
        .confirmationDialog(Text("ios.adjust.resetAll.confirm"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(role: .destructive) { editor.resetAll() } label: { AdjustmentText.command(.resetAll) }
        }
        .confirmationDialog(Text("ios.close.confirm"), isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("ios.close.discard", role: .destructive) { Task { await session.close() } }
        } message: {
            Text("ios.close.message")
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(model: session.exports, editor: editor, frame: Binding(get: { session.frame }, set: { session.frame = $0 }))
        }
        .sheet(isPresented: $showingLUTs) {
            LUTLibrarySheet(library: session.exports.luts, editor: editor)
                .environment(\.lookPickerShown, session.exports.luts.previews.shown)
        }
        .environment(\.lookPickerShown, session.exports.luts.previews.shown)
        // The LUT previews follow the photo, the edit and the library.
        .onChange(of: LookPreviewInputs(editor: editor, looks: session.exports.luts.looks), initial: true) { _, inputs in
            session.exports.luts.previews.update(editor, looks: inputs.looks)
        }
    }

    private var subtitle: Text {
        guard let size = editor.photoSize else { return Text(verbatim: "") }
        return Text(verbatim: "\(size.width) × \(size.height)")
    }

    // MARK: - Layout

    @ViewBuilder private var workspace: some View {
        switch layout {
        case .inspector:
            canvas
        case .dock(let axis, let large):
            let dock = EditorDock(recipe: recipe, panel: panel, pane: $pane, frameOn: session.frame.isEnabled,
                                  photo: photo,
                                  axis: axis, large: large,
                                  onEditingChanged: { editor.editingChanged($0, $1) }, onReset: reset,
                                  onBypass: bypass, onGeometryEditing: { editor.editingGeometry($0) },
                                  onLUTLibrary: { showingLUTs = true },
                                  aiUnavailable: aiUnavailable) {
                FrameDock(settings: Binding(get: { session.frame }, set: { session.frame = $0 }),
                          photoSize: photoSize, misfits: session.frameMisfits, axis: axis, large: large)
            }
            .disabled(locksEditing)
            if axis == .horizontal {
                VStack(spacing: 0) {
                    canvas
                    dock
                }
            } else {
                HStack(spacing: 0) {
                    canvas
                    dock
                }
            }
        }
    }

    private var canvas: some View {
        EditorCanvas(session: session, editor: editor, comparison: comparison, splitRatio: $splitRatio,
                     transform: $transform, framed: pane == .frame, cropping: pane == .crop,
                     framePadding: isPad ? 56 : Space.s5, holdingOriginal: $holdingOriginal)
    }

    private var undoButton: some View {
        Button {
            editor.commitDrag()
            undoManager?.undo()
        } label: {
            Label("ios.toolbar.undo", systemImage: "arrow.uturn.backward")
        }
    }

    private var redoButton: some View {
        Button {
            editor.commitDrag()
            undoManager?.redo()
        } label: {
            Label("ios.toolbar.redo", systemImage: "arrow.uturn.forward")
        }
    }

    private var inspector: some View {
        let groups = DockGroup.tabs(panel.groups(for: editor.recipe))
        return VStack(spacing: 0) {
            SidebarTabs(groups: groups, pane: $pane, cropOn: !editor.recipe.geometry.isIdentity,
                        frameOn: session.frame.isEnabled, onBypass: bypass)
                .padding(.horizontal, Space.s4)
                .padding(.top, Space.s2)
                .padding(.bottom, Space.s3)
            switch pane {
            case .frame:
                FramePanel(settings: Binding(get: { session.frame }, set: { session.frame = $0 }),
                           photoSize: photoSize, misfits: session.frameMisfits,
                           output: session.frameLayout.map { ($0.width, $0.height) })
            case .crop:
                ScrollView {
                    GeometryInspector(geometry: geometry, photo: photo, style: .touch,
                                      onEditingChanged: { editor.editingGeometry($0) })
                        .padding(.bottom, Space.s5)
                }
            case .group(let group):
                let tab = groups.first { $0.contains(group) } ?? groups.first
                ScrollView {
                    if let aiUnavailable, tab?.id == .hdr {
                        Label { aiUnavailable } icon: { Image(systemName: "info.circle") }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, Space.s2)
                    }
                    AdjustmentInspector(recipe: recipe, panel: panel, style: .touch,
                                        only: tab.map { Set($0.states.map(\.group)) },
                                        onEditingChanged: { editor.editingChanged($0, $1) }, onReset: reset,
                                        onLUTLibrary: { showingLUTs = true })
                        .id(tab?.id)
                        .padding(.bottom, Space.s5)
                }
            }
        }
        .disabled(locksEditing)
    }

    /// The photo's own size, for the crop pane.
    private var photo: GeometrySize? {
        editor.source.map { GeometrySize(width: Double($0.pixelSize.width), height: Double($0.pixelSize.height)) }
    }

    /// The crop pane's writes, through the recipe so they are undo steps.
    private var geometry: Binding<Geometry> {
        Binding(get: { editor.recipe.geometry }, set: { geometry in
            var recipe = editor.recipe
            recipe.geometry = geometry
            editor.setRecipe(recipe)
        })
    }

    // MARK: - Editing

    /// The controls rest while an export runs, and while a photo is on its
    /// way in: before the first one there is nothing to adjust, and edits to
    /// the photo being replaced would be dropped with it.
    private var locksEditing: Bool {
        session.exports.isRunning || editor.source == nil || session.loading
    }

    /// The controls' writes; spaces chosen on the look are recorded in the
    /// library for its LUT.
    private var recipe: Binding<Recipe> {
        Binding(get: { editor.recipe }, set: { editor.setRecipe($0) })
    }

    private var panel: AdjustmentPanel {
        AdjustmentPanel(context: AdjustmentContext(
            sourceValues: editor.source?.sourceValues ?? [:], automaticValues: editor.automaticValues,
            capabilities: editor.source?.capabilities ?? [], unavailableOptions: editor.unavailableOptions,
            luts: session.exports.luts.choices, lookSpaces: session.exports.luts.spaces,
            lutPreviews: session.exports.luts.previews.images))
    }

    /// Why AI cannot be chosen on this device, as on the Mac's AI status line.
    private var aiUnavailable: Text? {
        if case .unavailable = editor.aiStatus { return Text("ios.ai.unavailable") }
        return nil
    }

    private var photoSize: (width: Int, height: Int)? {
        editor.photoSize.map { ($0.width, $0.height) }
    }

    private func reset(_ reset: AdjustmentReset) {
        switch reset {
        case .group(let group): editor.resetGroup(group)
        case .all: editor.resetAll()
        }
    }

    /// Holding a group's tab shows the photo without it (never undone).
    private func bypass(_ group: AdjustmentGroupID, _ on: Bool) {
        if on { editor.bypassedGroups.insert(group) } else { editor.bypassedGroups.remove(group) }
    }

    /// What the editor needs for detail tiles: the visible part of the photo
    /// in source pixels and which renditions are on screen.
    private var viewport: CanvasViewport? {
        guard let transform, let photo = editor.canvasPhotoSize,
              transform.imageSize == CGSize(width: photo.width, height: photo.height),
              let visible = transform.visibleSourceRect else { return nil }
        let mode = EditorCanvas.mode(editor, comparison: comparison, holding: holdingOriginal)
        return CanvasViewport(visible: visible,
                              displayedWidth: Double(transform.displayedSize.width * transform.backingScale),
                              showsEdited: mode != .original, showsOriginal: mode != .edited)
    }

    private var hasOriginal: Bool {
        editor.originalFrame.flatMap { $0.request.sourceID == editor.frame?.request.sourceID ? $0 : nil } != nil
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // As in Photos: close, then undo and redo on the left; more and
        // Export on the right.
        ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) { requestClose() }
                .disabled(session.exports.isRunning)
        }
        ToolbarSpacer(.fixed, placement: .topBarLeading)
        ToolbarItemGroup(placement: .topBarLeading) {
            // Read with the recipe, so the buttons follow every step.
            let _ = editor.recipe
            undoButton.disabled(undoManager?.canUndo != true || locksEditing)
            redoButton.disabled(undoManager?.canRedo != true || locksEditing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            moreMenu
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            // Closed while another photo is on its way in (R26-002).
            Button {
                editor.commitDrag()
                session.exports.reset()
                showingExport = true
            } label: {
                Label("ios.toolbar.export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glassProminent)
            .tint(Color.hdr.accentFill)
            .disabled(!session.exports.isSettled(editor))
        }
        if layout == .inspector {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation { showsInspector.toggle() } } label: {
                    Label("ios.toolbar.inspector", systemImage: "sidebar.trailing")
                }
            }
        }
    }

    /// Adjusted, Original or Split (§5.4), as a submenu of More that names
    /// the current choice.
    private var comparisonMenu: some View {
        Picker(selection: $comparison) {
            Label("ios.view.edited", systemImage: "wand.and.sparkles").tag(Comparison.edited)
            Label("ios.view.original", systemImage: "photo").tag(Comparison.original)
            Label("ios.view.split", systemImage: "rectangle.split.2x1").tag(Comparison.split)
                .disabled(pane == .frame)
        } label: {
            Label("ios.compare.button", systemImage: "square.split.2x1")
        }
        .pickerStyle(.menu)
        // Still open while Original or Split waits for its original (or it
        // failed), so Adjusted can be chosen again.
        .disabled(!hasOriginal && comparison == .edited)
    }

    private var moreMenu: some View {
        Menu {
            Section { comparisonMenu }
            Section {
                Button("ios.menu.choosePhoto", systemImage: "photo.on.rectangle") { pickingPhoto = true }
                Button("ios.file.openMenu", systemImage: "folder") { importingFile = true }
            }
            .disabled(!session.exports.canOpenPhoto)
            Section {
                Button("ios.lut.manage", systemImage: "camera.filters") { showingLUTs = true }
                Button("ios.lut.import", systemImage: "square.and.arrow.down") { importingLUTs = true }
            }
            Section {
                Button(role: .destructive) { confirmingReset = true } label: {
                    Label { AdjustmentText.command(.resetAll) } icon: { Image(systemName: "arrow.counterclockwise") }
                }
                .disabled(locksEditing)
            }
        } label: {
            Label("ios.toolbar.more", systemImage: "ellipsis")
        }
    }

    /// Closing drops the photo and its edit; with edits, after asking.
    private func requestClose() {
        editor.commitDrag()
        if undoManager?.canUndo == true {
            confirmingClose = true
        } else {
            Task { await session.close() }
        }
    }
}
