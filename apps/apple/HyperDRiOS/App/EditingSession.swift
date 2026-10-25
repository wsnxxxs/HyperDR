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
        /// A drop, copied in once the editor is up so the copy shows progress.
        case dropped(NSItemProvider)

        /// Where the photo comes from, for the diagnostic log.
        var origin: String {
            switch self {
            case .library: "the photo library"
            case .file: "Files"
            case .dropped: "a drop"
            }
        }
    }

    /// What an open is waiting for, from the request until the photo's first
    /// frame is on the canvas. After `fetching`, the editor's own
    /// `openingPhase` (OPENING.md): coarse attribution, not a percentage.
    enum OpeningStage: Equatable {
        /// The original is being copied in: from the library (possibly a
        /// download from iCloud), from Files or from a drop.
        case fetching
        /// The editor is reading the copy.
        case reading
        /// A RAW's decoder is being set up.
        case loadingDecoder
        /// The photo's pixels are being decoded or developed.
        case developing
        /// The photo is being analysed for its preview.
        case preparingPreview
        /// The photo is open; its first frame is rendering.
        case rendering
        /// The photo is open but its first frame failed to render.
        case failed
    }

    /// Nil when this device cannot render (no Metal).
    let editor: RecipeEditor?
    let exports = IOSExportModel()

    /// Only newly opened RAWs use this preference. The photo already open and
    /// its export keep the decoder recorded in the recipe.
    var rawDecoderPreference: RAWDecoderPreference {
        didSet {
            guard rawDecoderPreference != oldValue else { return }
            rawDecoderPreference.save(to: defaults)
        }
    }
    @ObservationIgnored private let defaults: UserDefaults

    /// The frame chosen for exports. Its look is kept across launches as on
    /// the Mac; it is off for every photo until turned on for that photo.
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
    /// The original is being copied in (part of `loading`).
    private(set) var fetching = false
    /// How much of the copy has arrived, when the system reports it (a
    /// download from iCloud); nil when unknown.
    private(set) var fetchFraction: Double?
    /// The editor is on screen: from the first request until it is closed.
    var isEditing = false
    /// The last request failed before any photo was open.
    private(set) var openFailed = false
    /// Say so on the library: set once the editor has gone, since an alert
    /// raised while the editor is still being dismissed is dropped.
    var showsOpenFailure = false
    /// Most failures use the existing generic message; a forced RAW developer
    /// names the version the system could not supply for this photo.
    private(set) var openFailureMessage: LocalizedStringKey = "ios.error.load"
    /// A failure over an open photo, shown for a moment.
    var notice: LocalizedStringKey?
    /// A failure over an open photo that is too long for `notice`: the RAW of
    /// another camera that nothing here can develop. Shown as an alert.
    var editorFailure: LocalizedStringKey?

    @ObservationIgnored private var load: Task<Void, Never>?
    @ObservationIgnored private var factsTask: Task<Void, Never>?
    @ObservationIgnored private var request: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rawDecoderPreference = .load(from: defaults)
        editor = (try? RenderSession()).map { RecipeEditor(renderer: $0) }
        editor?.undo.actionName = Self.undoName
        editor?.onLookSpacesChanged = { [weak luts = exports.luts] old, new in
            luts?.record(from: old, to: new)
        }
        Task { [editor, exports] in
            if let editor { await exports.luts.refresh(into: editor) }
        }
        exports.framing = framing
    }

    var isAvailable: Bool { editor != nil }

    /// Where the open in progress is, nil once the new photo's first frame
    /// is shown (or nothing is opening).
    var openingStage: OpeningStage? {
        guard let editor else { return nil }
        if loading, fetching { return .fetching }
        switch editor.openingPhase {
        case .reading: return .reading
        case .loadingDecoder: return .loadingDecoder
        case .developing: return .developing
        case .preparingPreview: return .preparingPreview
        case .rendering: return .rendering
        case nil: break
        }
        // Between the copy and the editor's first phase.
        if loading { return .reading }
        // The phase is cleared when the first frame fails: the frame still
        // belongs to the previous photo (or none).
        guard let source = editor.source, editor.frameSource?.id != source.id else { return nil }
        return editor.renderFailure == nil ? .rendering : .failed
    }

    /// The photo's preview failed to follow an edit: its first frame is on
    /// screen but a later render failed, so the canvas lags the controls.
    /// A first frame that fails is `openingStage == .failed` instead; a
    /// changed file says so on its own.
    var previewFailed: Bool {
        guard let editor, !loading, let source = editor.source, editor.frameSource?.id == source.id else { return false }
        return editor.renderFailure != nil && !editor.sourceChanged
    }

    /// What export lays its frame out from.
    private var framing: IOSExportModel.Framing { .init(settings: frame, facts: facts) }

    /// The photo's name, for the iPad's title.
    var photoName: String? { editor?.source == nil ? nil : photo?.url.lastPathComponent }

    private static func undoName(_ edit: RecipeEdit) -> String {
        switch edit {
        case .parameter(let id): return Adjustments.declaration(id).map { AdjustmentText.undoName($0) } ?? id
        case .resetGroup(let group): return AdjustmentText.undoName(.group(group))
        case .resetAll: return AdjustmentText.undoName(.all)
        case .geometry: return AdjustmentText.undoGeometryName()
        }
    }

    // MARK: - Opening

    /// Other iPad scenes share the default, while keeping their open recipes.
    func refreshRAWDecoderPreference() { rawDecoderPreference = .load(from: defaults) }

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
        showsOpenFailure = false
        openFailureMessage = "ios.error.load"
        editorFailure = nil
        // A notice belongs to the photo it was about.
        notice = nil
        isEditing = true
        load?.cancel()
        refreshRAWDecoderPreference()
        let rawDecoderPreference = self.rawDecoderPreference
        load = Task { await self.load(source, id: id, rawDecoderPreference: rawDecoderPreference) }
    }

    /// Copies the original into our own file (library: as a file, `.current`
    /// keeps HEIC, DNG and gain maps; Files: inside its security scope) and
    /// opens it. The previous photo stays on screen until the new one is
    /// ready, and its copy is removed once the new one is open.
    private func load(_ source: Source, id: UUID, rawDecoderPreference: RAWDecoderPreference) async {
        // Whatever happens below, this request no longer holds export closed.
        defer { exports.photoRequestEnded(id) }
        // An export that started meanwhile keeps its photo: drop the request.
        guard exports.canOpenPhoto, let editor else { return }
        loading = true
        fetching = true
        fetchFraction = nil
        // A newer request has started its own load; leave its spinner alone.
        defer { if request == id { loading = false; fetching = false; fetchFraction = nil } }
        var imported: ImportedPhoto?
        DiagnosticLog.notice("Session", "Opening a photo from \(source.origin)")
        do {
            switch source {
            case .library(let item):
                imported = try await transfer(id) { item.loadTransferable(type: ImportedPhoto.self, completionHandler: $0) }
            case .file(let url):
                imported = try await Task.detached(priority: .userInitiated) { try ImportedPhoto.copyFromFiles(url) }.value
            case .dropped(let provider):
                imported = try await transfer(id) { done in
                    provider.loadTransferable(type: ImportedPhoto.self) { done($0.map(Optional.some)) }
                }
            }
            guard let imported else { throw CocoaError(.fileReadUnknown) }
            // The Files copy runs detached and ignores this task's cancellation:
            // a request superseded meanwhile stops here, and its copy is removed.
            try Task.checkCancellation()
            fetching = false
            fetchFraction = nil
            // The export session hashes the copy while the editor decodes it.
            exports.photoOpening(imported.url)
            await exports.prepareRAWCompatibility()
            try Task.checkCancellation()
            try await editor.open(imported.url, rawDecoderPreference: rawDecoderPreference)
            photo?.discard()
            photo = imported
            // The frame's look carries over; being on does not: each photo
            // opens without a frame until it is turned on for it.
            frame.isEnabled = false
            exports.photoOpened(imported.url)
            readFacts(imported.url)
        } catch {
            if let imported { exports.photoFailed(imported.url) }
            imported?.discard()
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            DiagnosticLog.error("Session", "\(imported == nil ? "Import" : "Open") failed: \(EditorLog.describe(error))")
            if case RenderError.unsupportedRAWDecoder(let version) = error {
                openFailureMessage = "ios.error.rawDecoderUnavailable \(version)"
            } else if case RenderError.unsupportedRAWCompatibility(let converter) = error {
                openFailureMessage = "ios.error.rawDecoderUnavailable \(converter)"
            } else if case RenderError.rawUnsupported(let camera) = error {
                if let camera, !camera.isEmpty {
                    openFailureMessage = "ios.error.rawUnsupported.model \(camera)"
                } else {
                    openFailureMessage = "ios.error.rawUnsupported"
                }
            }
            if editor.source == nil {
                openFailed = true
                isEditing = false
            } else if case RenderError.rawUnsupported = error {
                editorFailure = openFailureMessage
            } else {
                notice = openFailureMessage
            }
        }
    }

    /// Runs a transfer that reports its `Progress`, publishing how far it
    /// is while `id` is the current request. Cancelling the task cancels the
    /// transfer and returns at once; a copy that still arrives is removed.
    private func transfer(_ id: UUID,
                          _ start: (@escaping @Sendable (Result<ImportedPhoto?, any Error>) -> Void) -> Progress)
        async throws -> ImportedPhoto? {
        let handoff = TransferHandoff()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handoff.begin(continuation)
                let progress = start { handoff.finish($0) }
                handoff.watch(progress) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.request == id, self.fetching else { return }
                        self.fetchFraction = fraction
                    }
                }
            }
        } onCancel: {
            handoff.finish(.failure(CancellationError()))
        }
    }

    /// The Exif is read off the main actor; a newer photo replaces it.
    private func readFacts(_ url: URL) {
        factsTask?.cancel()
        facts = CaptureFacts()
        factsTask = Task {
            let read = await Task.detached(priority: .utility) {
                let original = CaptureFacts.read(url)
                guard let converted = RenderEngine.rawCompatibilitySourceURL(for: url), converted != url else { return original }
                return original.merging(CaptureFacts.read(converted))
            }.value
            if !Task.isCancelled { facts = read }
        }
    }

    /// The editor has been dismissed: an open that failed can be reported now.
    func editorDismissed() {
        if openFailed { showsOpenFailure = true }
        openFailed = false
    }

    /// Back to the library: the photo, its copy and its export session go.
    /// Not while an export runs.
    func close() async {
        guard !exports.isRunning, let editor else { return }
        load?.cancel()
        request = nil
        loading = false
        fetching = false
        fetchFraction = nil
        notice = nil
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
        guard frame.isEnabled, let size = editor?.photoSize else { return nil }
        return FrameLayouts.layout(frame, width: size.width, height: size.height)
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

/// One transfer's continuation, resumed exactly once: by the transfer's
/// completion or by cancellation, whichever comes first.
private nonisolated final class TransferHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ImportedPhoto?, any Error>?
    private var pending: Result<ImportedPhoto?, any Error>?
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    private var done = false

    func begin(_ continuation: CheckedContinuation<ImportedPhoto?, any Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Follows the transfer's fraction; cancelled already, cancels it.
    func watch(_ progress: Progress, _ report: @escaping @Sendable (Double) -> Void) {
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            report(progress.fractionCompleted)
        }
        lock.lock()
        let finished = done
        if !finished {
            self.progress = progress
            self.observation = observation
        }
        lock.unlock()
        if finished {
            observation.invalidate()
            progress.cancel()
        }
    }

    func finish(_ result: Result<ImportedPhoto?, any Error>) {
        lock.lock()
        guard !done else {
            lock.unlock()
            // Cancelled first: the copy that arrived afterwards is nobody's.
            if case .success(let photo?) = result { Task { @MainActor in photo.discard() } }
            return
        }
        done = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        let progress = self.progress
        observation?.invalidate()
        observation = nil
        lock.unlock()
        if case .failure(let error) = result, error is CancellationError { progress?.cancel() }
        continuation?.resume(with: result)
    }
}
