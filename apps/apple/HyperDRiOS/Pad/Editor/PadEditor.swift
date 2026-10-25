import HyperDRDesign
import HyperDRRecipe
import HyperDRRender
import PhotosUI
import SwiftUI

/// The iPad editor, the Studio (docs/design/ipad-studio.md §3): the photo on
/// a black stage, the canvas bar under it, and one floating panel with the
/// tool rail and the current tool, standing on the right or lying along the
/// foot (`PadLayout`). The toolbar keeps the Photos order: close, undo and
/// redo lead; More, the panel and Export trail.
///
/// Everything the iPhone editor does, it does from the same models: undo
/// steps on the scene's undo manager (⌘Z, the three-finger swipe), holding
/// the canvas for the original, detail tiles when zoomed in, the crop box on
/// the canvas while Crop is open and the export's frame while Frame is.
struct PadEditor: View {
    let session: EditingSession
    let editor: RecipeEditor

    @State private var tool = PadTool.group(.hdr)
    @State private var expanded = true
    /// A control to scroll to once its tool is shown (the film exposure note's tap).
    @State private var revealed: String?
    /// Where the panel is now, for the toolbar's panel button.
    @State private var placement = PadLayout.Placement.side
    @State private var comparison = Comparison.edited
    @State private var splitRatio = 0.5
    @State private var holdingOriginal = false
    @State private var transform: CanvasTransform?
    @State private var headroom = HeadroomSnapshot()
    @State private var zoomRequest: CanvasZoomRequest?
    @State private var scopes = PadScopes()
    @State private var channels = HistogramChannels.luma
    @State private var showingExport = false
    @State private var showingLUTs = false
    @State private var importingLUTs = false
    @State private var importingFile = false
    @State private var pickingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var confirmingReset = false
    @State private var confirmingClose = false
    @State private var showingCompatibility = false
    @Environment(\.undoManager) private var undoManager
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        NavigationStack {
            GeometryReader { outer in
                let bottomInset = outer.safeAreaInsets.bottom
                GeometryReader { proxy in
                    let layout = PadLayout(size: proxy.size, bottomInset: bottomInset, expanded: expanded)
                    ZStack(alignment: .topLeading) {
                        canvas
                            .frame(width: layout.canvas.width, height: layout.canvas.height)
                            .position(x: layout.canvas.midX, y: layout.canvas.midY)
                        canvasBar
                            .frame(width: layout.bar.width, height: layout.bar.height)
                            .position(x: layout.bar.midX, y: layout.bar.midY)
                        panel(layout)
                            .frame(width: layout.panel.width, height: layout.panel.height)
                            .position(x: layout.panel.midX, y: layout.panel.midY)
                    }
                    .animation(.smooth(duration: 0.35), value: layout)
                    .onChange(of: layout.placement, initial: true) { _, new in placement = new }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
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
            .navigationTitle(Text(verbatim: session.photoName ?? ""))
            .navigationSubtitle(subtitle)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
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
        // The eyedropper belongs to the photo it was started on, and to the adjusting tools.
        .onChange(of: editor.source?.id) { session.whiteBalance.reset(); session.curvePick.picker.reset() }
        .onChange(of: locksEditing) { if locksEditing { session.whiteBalance.reset(); session.curvePick.picker.reset() } }
        .onChange(of: tool, initial: true) { _, tool in
            session.whiteBalance.reset()
            session.curvePick.picker.reset()
            // The frame is drawn from the whole photo: leave zoom and split behind.
            // The crop pane shows the edit alone (`EditorCanvas.mode`) and keeps
            // the comparison chosen for when it is left.
            if tool == .frame, comparison != .edited { comparison = .edited }
            // The crop is edited on the whole photo, rendered once; leaving renders it cropped.
            editor.isEditingCrop = tool == .crop && !showingExport
        }
        .onChange(of: tools) { _, tools in
            // A JPEG has no Detail: back to the first tool rather than none.
            if !tools.contains(tool), let first = tools.first { tool = first }
        }
        .onChange(of: ScopeTrigger(editor: editor), initial: true) { scopes.update(editor) }
        .onChange(of: editor.source?.id) { scopes.reset() }
        .confirmationDialog(Text("ios.adjust.resetAll.confirm"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(role: .destructive) { editor.resetAll() } label: { AdjustmentText.command(.resetAll) }
        }
        .confirmationDialog(Text("ios.close.confirm"), isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("ios.close.discard", role: .destructive) { Task { await session.close() } }
        } message: {
            Text("ios.close.message")
        }
        .rawCompatibilityAlert(editor: editor, isPresented: $showingCompatibility)
        .sheet(isPresented: $showingExport, onDismiss: { editor.isEditingCrop = tool == .crop }) {
            ExportSheet(model: session.exports, editor: editor, frame: Binding(get: { session.frame }, set: { session.frame = $0 }),
                        preview: AnyView(PadExportPreview(session: session, editor: editor)))
        }
        .sheet(isPresented: $showingLUTs) {
            LUTLibrarySheet(library: session.exports.luts, editor: editor)
                .environment(\.lookPickerShown, session.exports.luts.previews.shown)
        }
        .environment(\.lookPickerShown, session.exports.luts.previews.shown)
        // The look previews follow the photo, the edit and the library.
        .onChange(of: LookPreviewInputs(editor: editor, looks: session.exports.luts.looks), initial: true) { _, inputs in
            session.exports.luts.previews.update(editor, looks: inputs.looks)
        }
    }

    private var subtitle: Text {
        guard let size = editor.photoSize else { return Text(verbatim: "") }
        return Text(verbatim: "\(size.width) × \(size.height)")
    }

    // MARK: - Canvas

    /// The canvas keeps a margin from the window's edges, so the fitted photo
    /// never touches them; zoomed in, it is clipped there.
    private var canvas: some View {
        EditorCanvas(session: session, editor: editor, comparison: comparison, splitRatio: $splitRatio,
                     transform: $transform, framed: tool == .frame, cropping: tool == .crop,
                     framePadding: 40, holdingOriginal: $holdingOriginal, whiteBalance: session.whiteBalance,
                     targetPicker: session.curvePick.picker,
                     zoomRequest: zoomRequest, onHeadroom: { headroom = $0 })
            .clipped()
            .padding(.horizontal, 18)
            .padding(.top, 4)
    }

    @ViewBuilder private var canvasBar: some View {
        if tool != .crop {
            PadCanvasBar(comparison: $comparison, canCompare: hasOriginal || comparison != .edited,
                         allowsSplit: tool != .frame, zoom: tool == .frame ? nil : zoom, onZoom: toggleZoom,
                         headroom: headroom, showsHDR: editor.frame?.hasHDRContent == true && !editor.previewsAsSDR)
                .disabled(editor.frame == nil)
                .transition(.opacity)
        }
    }

    /// Fit, or the share of the photo's pixels shown, as the canvas bar says it.
    private var zoom: PadCanvasBar.Zoom? {
        guard let transform, transform.imageSize.width > 0, transform.displayedSize.width > 0 else { return nil }
        if transform.zoom <= CanvasTransform.minZoom + 0.001 { return .fit }
        let scale = Double(transform.displayedSize.width * transform.backingScale / transform.imageSize.width)
        return .percent(Int((scale * 100).rounded()))
    }

    private func toggleZoom() {
        zoomRequest = CanvasZoomRequest(kind: zoom == .fit ? .actualPixels : .fit)
    }

    /// What the editor needs for detail tiles: the visible part of the photo
    /// in source pixels and which renditions are on screen.
    private var viewport: CanvasViewport? {
        guard let transform, let photo = editor.canvasPhotoSize,
              transform.imageSize == CGSize(width: photo.width, height: photo.height),
              let visible = transform.visibleSourceRect else { return nil }
        let mode = EditorCanvas.mode(editor, comparison: comparison, holding: holdingOriginal, cropping: tool == .crop)
        return CanvasViewport(visible: visible,
                              displayedWidth: Double(transform.displayedSize.width * transform.backingScale),
                              showsEdited: mode != .original, showsOriginal: mode != .edited)
    }

    private var hasOriginal: Bool {
        editor.originalFrame.flatMap { $0.request.sourceID == editor.frame?.request.sourceID ? $0 : nil } != nil
    }

    // MARK: - Panel

    private var groups: [AdjustmentGroupState] { panel.groups(for: editor.recipe) }
    private var tools: [PadTool] { PadTool.tools(groups) }

    private func panel(_ layout: PadLayout) -> some View {
        let groups = groups
        return PadPanel(placement: layout.placement, expanded: expanded, tool: tool, reveal: revealed,
                        onRevealed: { revealed = nil }) { axis in
            PadToolRail(items: PadTool.tools(groups).map { PadRailItem(tool: $0, marked: isModified($0, groups)) },
                        selection: tool, axis: axis, choose: choose, onBypass: bypass)
        } histogram: {
            PadHistogram(current: scopes.current, original: scopes.original, channels: $channels)
        } header: {
            header(groups, compact: layout.placement == .bottom)
                .disabled(locksEditing)
        } content: {
            toolContent(columns: layout.columns)
                .environment(\.whiteBalancePicking, session.whiteBalance.picking)
                .environment(\.curvePicking, session.curvePick.picking)
                .environment(\.revealControl) { reveal($0) }
                .disabled(locksEditing)
        } footer: {
            if editor.source != nil {
                PadPhotoInfo(facts: session.facts, name: session.photoName, domain: editor.source?.domain,
                             size: editor.photoSize.map { ($0.width, $0.height) },
                             compatibility: editor.sourceCompatibility)
            }
        }
    }

    /// Opens the tool that holds the control and scrolls to its row.
    private func reveal(_ id: String) {
        guard let group = Adjustments.declaration(id)?.group else { return }
        withAnimation(.smooth(duration: 0.3)) {
            tool = .group(group)
            expanded = true
        }
        revealed = id
    }

    /// A tool from the rail; the current one again folds the panel away.
    private func choose(_ next: PadTool) {
        withAnimation(.smooth(duration: 0.3)) {
            if next == tool, expanded {
                expanded = false
            } else {
                tool = next
                expanded = true
            }
        }
    }

    private func isModified(_ tool: PadTool, _ groups: [AdjustmentGroupState]) -> Bool {
        switch tool {
        case .group(let group): groups.first { $0.group == group }?.isModified ?? false
        case .crop: !editor.recipe.geometry.isIdentity
        case .frame: session.frame.isEnabled
        }
    }

    private func header(_ groups: [AdjustmentGroupState], compact: Bool) -> PadToolHeader {
        let histogram = compact ? AnyView(PadHistogram(current: scopes.current, original: scopes.original,
                                                        channels: $channels, compact: true)) : nil
        switch tool {
        case .group(let group):
            let state = groups.first { $0.group == group }
            let power = state?.headerToggle.map { toggle in
                Binding(get: { toggle.isOn }, set: { on in
                    var recipe = editor.recipe
                    panel.set(toggle.id, isOn: on, in: &recipe)
                    editor.setRecipe(recipe)
                })
            }
            return PadToolHeader(title: tool.title, subtitle: group == .hdr ? Text("ipad.hdr.subtitle") : nil,
                                 power: power, canReset: state?.isModified == true && !locksEditing,
                                 onReset: { editor.resetGroup(group) }, histogram: histogram)
        case .crop:
            return PadToolHeader(title: tool.title, canReset: !editor.recipe.geometry.isIdentity && !locksEditing,
                                 onReset: { geometry.wrappedValue = .identity }, histogram: histogram)
        case .frame:
            return PadToolHeader(title: tool.title, histogram: histogram)
        }
    }

    @ViewBuilder private func toolContent(columns: Int) -> some View {
        switch tool {
        case .group(.look):
            PadLookTool(recipe: recipe, panel: panel, columns: columns, revealing: revealed,
                        onEditingChanged: { editor.editingChanged($0, $1) }, onReset: reset,
                        onLibrary: { showingLUTs = true })
        case .group(let group):
            PadGroupControls(recipe: recipe, panel: panel, group: group, columns: columns,
                             onEditingChanged: { editor.editingChanged($0, $1) }, onReset: reset,
                             aiUnavailable: group == .hdr ? aiUnavailable : nil)
        case .crop:
            PadCropTool(geometry: geometry, photo: photo, columns: columns, upright: editor.upright,
                        onEditingChanged: { editor.editingGeometry($0) })
        case .frame:
            PadFrameTool(settings: Binding(get: { session.frame }, set: { session.frame = $0 }),
                         photoSize: editor.photoSize.map { ($0.width, $0.height) }, misfits: session.frameMisfits,
                         output: session.frameLayout.map { ($0.width, $0.height) }, columns: columns)
        }
    }

    // MARK: - Editing

    /// The controls rest while an export runs, and while a photo is on its
    /// way in: before the first one there is nothing to adjust, and edits to
    /// the photo being replaced would be dropped with it.
    private var locksEditing: Bool {
        session.exports.isRunning || editor.source == nil || session.loading
    }

    private var recipe: Binding<Recipe> {
        Binding(get: { editor.recipe }, set: { editor.setRecipe($0) })
    }

    /// The crop tool's writes, through the recipe so they are undo steps.
    private var geometry: Binding<Geometry> {
        Binding(get: { editor.recipe.geometry }, set: { geometry in
            var recipe = editor.recipe
            recipe.geometry = geometry
            editor.setRecipe(recipe)
        })
    }

    /// The photo's own size, for the crop tool.
    private var photo: GeometrySize? {
        editor.source.map { GeometrySize(width: Double($0.pixelSize.width), height: Double($0.pixelSize.height)) }
    }

    private var panel: AdjustmentPanel {
        AdjustmentPanel(context: AdjustmentContext(
            sourceValues: editor.source?.sourceValues ?? [:], automaticValues: editor.automaticValues,
            capabilities: editor.source?.capabilities ?? [], unavailableOptions: editor.unavailableOptions,
            luts: session.exports.luts.choices, lookSpaces: session.exports.luts.spaces,
            lutPreviews: session.exports.luts.previews.images))
    }

    /// Why AI cannot be chosen: this build has no model, or this device cannot
    /// run it; as on the Mac's AI status line.
    private var aiUnavailable: Text? {
        if !editor.modelIncluded { return Text("ios.ai.notIncluded") }
        if case .unavailable = editor.aiStatus { return Text("ios.ai.unavailable") }
        return nil
    }

    private func reset(_ reset: AdjustmentReset) {
        switch reset {
        case .group(let group): editor.resetGroup(group)
        case .all: editor.resetAll()
        }
    }

    /// Holding a tool shows the photo without its group (never undone).
    private func bypass(_ group: AdjustmentGroupID, _ on: Bool) {
        if on { editor.bypassedGroups.insert(group) } else { editor.bypassedGroups.remove(group) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) { requestClose() }
                .disabled(session.exports.isRunning)
        }
        ToolbarSpacer(.fixed, placement: .topBarLeading)
        ToolbarItemGroup(placement: .topBarLeading) {
            // Read with the recipe, so the buttons follow every step.
            let _ = editor.recipe
            Button {
                editor.commitDrag()
                undoManager?.undo()
            } label: {
                Label("ios.toolbar.undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(undoManager?.canUndo != true || locksEditing)
            Button {
                editor.commitDrag()
                undoManager?.redo()
            } label: {
                Label("ios.toolbar.redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(undoManager?.canRedo != true || locksEditing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            moreMenu
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { withAnimation(.smooth(duration: 0.3)) { expanded.toggle() } } label: {
                Label("ipad.toolbar.panel",
                      systemImage: placement == .side ? "sidebar.trailing" : "rectangle.bottomthird.inset.filled")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            // Closed while another photo is on its way in (R26-002).
            Button {
                editor.commitDrag()
                session.exports.reset()
                editor.isEditingCrop = false
                showingExport = true
            } label: {
                // Named, not only a symbol: on the iPad there is room, and it is the way out.
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("ios.toolbar.export")
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.hdr.accentFill)
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!session.exports.isSettled(editor))
        }
    }

    private var moreMenu: some View {
        Menu {
            RAWCompatibilityMenuItem(editor: editor, showing: $showingCompatibility)
            Section {
                Button("ios.menu.choosePhoto", systemImage: "photo.on.rectangle") { pickingPhoto = true }
                Button("ios.file.openMenu", systemImage: "folder") { importingFile = true }
                    .keyboardShortcut("o", modifiers: .command)
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

/// What the histogram is measured again for: a new frame of the edit, and the
/// end of a drag.
private struct ScopeTrigger: Equatable {
    let request: EditorRenderRequest?
    let recipe: Recipe
    let dragging: Bool

    init(editor: RecipeEditor) {
        request = editor.frame?.request
        recipe = editor.recipe
        dragging = editor.isDragging
    }
}
