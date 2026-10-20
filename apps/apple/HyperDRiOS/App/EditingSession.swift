import HyperDRDesign
import HyperDRRecipe
import HyperDRRender
import Observation
import PhotosUI
import SwiftUI

/// The photo being edited and everything around it, for the whole scene: the
/// shared `RecipeEditor` on HyperDRRender, the export flow, the LUT library,
/// the presentation frame and the photo's capture facts.
///
/// Opening follows p7-2b §3.3: the original is copied into our own file
/// (`ImportedPhoto`), the editor decodes the copy while export's Kit session
/// opens and hashes it, and the previous photo stays until the new one is
/// open. Opening is refused while an export runs, and export is closed while
/// a photo is on its way in (R26-002, R26-004).
@MainActor @Observable final class EditingSession {
    /// Where a photo comes from.
    enum Source {
        case library(PhotosPickerItem)
        case file(URL)
        /// Already copied in (a drop).
        case imported(ImportedPhoto)
    }

    /// Nil when this device cannot render (no Metal).
    let editor: RecipeEditor?
    let exports = IOSExportModel()

    /// The frame chosen for exports, kept across launches as on the Mac.
    var frame = FrameSettings.load() {
        didSet {
            guard frame != oldValue else { return }
            frame.save()
            exports.framing = framing
        }
    }

    /// The copy the editor has open.
    private(set) var photo: ImportedPhoto?
    /// The open photo's Exif, for the frame's caption.
    private(set) var facts = CaptureFacts() {
        didSet { exports.framing = framing }
    }
    /// A photo is being copied or decoded.
    private(set) var loading = false
    /// The editor is on screen: from the first request until it is closed.
    var isEditing = false
    /// The last request failed before any photo was open.
    var openFailed = false
    /// A failure over an open photo, shown for a moment.
    var notice: LocalizedStringKey?

    @ObservationIgnored private var load: Task<Void, Never>?
    @ObservationIgnored private var factsTask: Task<Void, Never>?
    @ObservationIgnored private var request: UUID?

    init() {
        editor = (try? RenderSession()).map { RecipeEditor(renderer: $0) }
        editor?.undo.actionName = Self.undoName
        Task { [editor, exports] in
            if let editor { await exports.luts.refresh(into: editor) }
        }
        exports.framing = framing
    }

    var isAvailable: Bool { editor != nil }

    /// What export lays its frame out from.
    private var framing: IOSExportModel.Framing { .init(settings: frame, facts: facts) }

    /// The photo's name, for the iPad's title.
    var photoName: String? { editor?.source == nil ? nil : photo?.url.lastPathComponent }

    private static func undoName(_ edit: RecipeEdit) -> String {
        switch edit {
        case .parameter(let id): return Adjustments.declaration(id).map { AdjustmentText.undoName($0) } ?? id
        case .resetGroup(let group): return AdjustmentText.undoName(.group(group))
        case .resetAll: return AdjustmentText.undoName(.all)
        }
    }

    // MARK: - Opening

    /// Every way of opening a photo comes here. Not while an export runs:
    /// opening the next photo removes this one's copy and session. Export
    /// closes in the same step as the request is accepted, before its load
    /// starts (R26-004).
    func open(_ source: Source) {
        guard exports.canOpenPhoto, editor != nil else { return }
        let id = UUID()
        exports.photoRequested(id)
        request = id
        openFailed = false
        isEditing = true
        load?.cancel()
        load = Task { await self.load(source, id: id) }
    }

    /// Copies the original into our own file (library: as a file, `.current`
    /// keeps HEIC, DNG and gain maps; Files: inside its security scope) and
    /// opens it. The previous photo stays on screen until the new one is
    /// ready, and its copy is removed once the new one is open.
    private func load(_ source: Source, id: UUID) async {
        // Whatever happens below, this request no longer holds export closed.
        defer { exports.photoRequestEnded(id) }
        // An export that started meanwhile keeps its photo: drop the request.
        guard exports.canOpenPhoto, let editor else { return }
        loading = true
        // A newer request has started its own load; leave its spinner alone.
        defer { if request == id { loading = false } }
        var imported: ImportedPhoto?
        do {
            switch source {
            case .library(let item):
                imported = try await item.loadTransferable(type: ImportedPhoto.self)
            case .file(let url):
                imported = try await Task.detached(priority: .userInitiated) { try ImportedPhoto.copyFromFiles(url) }.value
            case .imported(let photo):
                imported = photo
            }
            guard let imported else { throw CocoaError(.fileReadUnknown) }
            // The Files copy runs detached and ignores this task's cancellation:
            // a request superseded meanwhile stops here, and its copy is removed.
            try Task.checkCancellation()
            // The export session hashes the copy while the editor decodes it.
            exports.photoOpening(imported.url)
            try await editor.open(imported.url)
            photo?.discard()
            photo = imported
            exports.photoOpened(imported.url)
            readFacts(imported.url)
        } catch {
            if let imported { exports.photoFailed(imported.url) }
            imported?.discard()
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if editor.source == nil {
                openFailed = true
                isEditing = false
            } else {
                notice = "ios.error.load"
            }
        }
    }

    /// The Exif is read off the main actor; a newer photo replaces it.
    private func readFacts(_ url: URL) {
        factsTask?.cancel()
        facts = CaptureFacts()
        factsTask = Task {
            let read = await Task.detached(priority: .utility) { CaptureFacts.read(url) }.value
            if !Task.isCancelled { facts = read }
        }
    }

    /// Back to the library: the photo, its copy and its export session go.
    /// Not while an export runs.
    func close() async {
        guard !exports.isRunning, let editor else { return }
        load?.cancel()
        request = nil
        loading = false
        isEditing = false
        factsTask?.cancel()
        await editor.close()
        exports.photoClosed()
        photo?.discard()
        photo = nil
        facts = CaptureFacts()
    }

    // MARK: - Frame

    /// The frame around the full-size photo, nil while it is off or before
    /// the photo is known, or when the engine refuses the style for this
    /// photo's proportions (`frameMisfits`).
    var frameLayout: FramePixelLayout? {
        guard frame.isEnabled, let size = editor?.source?.pixelSize else { return nil }
        return FrameLayouts.layout(frame, facts: facts, width: size.width, height: size.height)
    }

    /// The frame is on but does not fit this photo.
    var frameMisfits: Bool { frame.isEnabled && editor?.source != nil && frameLayout == nil }

    /// The caption as laid out for `layout`.
    func caption(for layout: FramePixelLayout) -> FrameCaption {
        frame.style.caption(frame, facts: facts, variant: layout.variant,
                            bandHeight: layout.referenceEdge > 0
                                ? Double(layout.caption.height) / Double(layout.referenceEdge) : nil)
    }
}
