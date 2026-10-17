import Foundation
import HyperDREngine
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class EditorModel {
    private(set) var engine: EngineStatus
    private(set) var workspace: Workspace
    private(set) var document: DocumentState?
    private(set) var display: DisplayState
    private(set) var alert: UserFacingError?
    let canvas = CanvasModel()
    /// The presentation frame, remembered across launches.
    var frame = FrameSettings.load() {
        didSet { if frame != oldValue { frame.save() } }
    }
    /// The open photograph's Exif, once `loadCaptureFacts` has read it.
    private(set) var captureFacts = CaptureFacts()

    private var selectedMode: ViewMode = .edited
    private(set) var hasReferenceFrame: Bool
    private(set) var hasEditedFrame: Bool
    @ObservationIgnored private let services: any EditorServices
    @ObservationIgnored private var photo: EditorPhoto?
    @ObservationIgnored private var adjustments: [String: Double] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var displayObserver: Task<Void, Never>?
    @ObservationIgnored private var displayPublication: Task<Void, Never>?
    @ObservationIgnored private var pendingDisplay: DisplayState?
    @ObservationIgnored private var openRollback: OpenSnapshot?
    @ObservationIgnored private var editedGainWeight: Double?

    private struct OpenSnapshot {
        var document: DocumentState?
        let photo: EditorPhoto?
        let reference: Bool
        let edited: Bool
        let viewMode: ViewMode
        let zoom: ZoomLevel
        let display: DisplayState
        let editedGainWeight: Double?
    }

    init(services: any EditorServices = FakeEditorServices(), document: DocumentState? = nil,
         alert: UserFacingError? = nil, photo: EditorPhoto? = nil,
         hasReferenceFrame: Bool = false, hasEditedFrame: Bool = false) {
        self.services = services
        engine = services.engineStatus
        display = services.displayState
        self.document = document
        workspace = document == nil ? .empty : .editing
        self.alert = alert
        self.photo = photo
        self.hasReferenceFrame = hasReferenceFrame
        self.hasEditedFrame = hasEditedFrame
        editedGainWeight = hasEditedFrame ? services.displayState.gainWeight : nil
        if !hasEditedFrame { display.gainWeight = nil }
        canvas.setImageSize(hasEditedFrame ? document?.pixelSize : nil)
        let updates = services.displayUpdates()
        displayObserver = Task { [weak self] in
            for await state in updates {
                guard !Task.isCancelled else { return }
                self?.receiveDisplay(state)
            }
        }
    }

    deinit {
        operation?.cancel()
        displayObserver?.cancel()
        displayPublication?.cancel()
    }

    var viewMode: ViewMode {
        get { selectedMode }
        set {
            guard isAvailable(newValue) else { return }
            selectedMode = newValue
            display.gainWeight = newValue == .edited ? editedGainWeight : nil
        }
    }

    var openableContentTypes: [UTType] { services.openableContentTypes }
    func canOpen(_ url: URL) -> Bool { services.canOpen(url) }

    func isAvailable(_ mode: ViewMode) -> Bool {
        switch mode {
        case .original: hasReferenceFrame
        case .edited: hasEditedFrame
        case .compare: false
        }
    }

    /// Q14: document describes the new source immediately, but the previous
    /// frames, mode and canvas geometry stay visible until its reference arrives.
    /// Any open failure restores the complete previous state, or the empty state.
    func open(_ urls: [URL]) {
        if case .failed(let error) = engine {
            alert = UserFacingError(code: "engine_unavailable", detail: error.detail)
            return
        }
        guard let url = urls.first(where: canOpen) else {
            alert = UserFacingError(code: "unsupported_format")
            return
        }

        operation?.cancel()
        generation += 1
        let ticket = generation
        var previous = openRollback ?? OpenSnapshot(document: document, photo: photo,
            reference: hasReferenceFrame, edited: hasEditedFrame, viewMode: selectedMode,
            zoom: canvas.zoom, display: display, editedGainWeight: editedGainWeight)
        previous.document?.isRefreshing = false
        openRollback = previous
        document = services.placeholder(for: url).openingDocument
        workspace = .editing
        alert = nil

        operation = Task { [weak self, services] in
            guard let self else { return }
            var candidate: EditorPhoto?
            do {
                let opened = try await services.open(url)
                candidate = opened
                try Task.checkCancellation()
                guard generation == ticket else { await services.close(opened); return }
                document = opened.openingDocument
                document?.phase = .rendering
                for await event in services.previews(for: opened, includingReference: true, adjustments: [:]) {
                    try Task.checkCancellation()
                    guard generation == ticket else { throw CancellationError() }
                    if case .failed(let error) = event { throw error }
                    if case .edited = event {
                        // Commit the opened photo before publishing ready. A new
                        // refresh or open may start before the stream ends.
                        photo = opened
                        adjustments = [:]
                        captureFacts = CaptureFacts()
                        openRollback = nil
                        operation = nil
                        apply(event)
                        if let old = previous.photo, old != opened { await services.close(old) }
                        return
                    }
                    apply(event)
                }
                try Task.checkCancellation()
                guard generation == ticket else { throw CancellationError() }
                throw UserFacingError(code: "internal_error")
            } catch {
                if let candidate, candidate != previous.photo { await services.close(candidate) }
                guard generation == ticket, !Task.isCancelled else { return }
                let error = error as? UserFacingError ?? UserFacingError(code: "internal_error", detail: String(describing: error))
                restore(previous, error: error)
                operation = nil
            }
        }
    }

    func closeDocument() {
        generation += 1
        operation?.cancel()
        operation = nil
        if let photo { Task { [services] in await services.close(photo) } }
        photo = nil
        openRollback = nil
        document = nil
        workspace = .empty
        alert = nil
        hasReferenceFrame = false
        hasEditedFrame = false
        selectedMode = .edited
        adjustments = [:]
        captureFacts = CaptureFacts()
        display.gainWeight = nil
        editedGainWeight = nil
        canvas.setImageSize(nil)
    }

    func dismissAlert() { alert = nil }

    // MARK: Frame

    func loadCaptureFacts() async {
        guard let photo else { return }
        let facts = await services.captureFacts(for: photo)
        guard self.photo == photo else { return }
        captureFacts = facts
    }

    /// The caption the frame sets for this photograph.
    var frameCaption: FrameCaption { frame.style.caption(frame, facts: captureFacts) }

    /// The engine's layout of the frame around the full-size photograph, or of
    /// the bare photograph while the frame is off. Nil without a photo size.
    var frameLayout: FrameLayout? {
        guard let size = document?.pixelSize else { return nil }
        let spec = frame.isEnabled ? frame.engineFrame(hasCaption: !frameCaption.isEmpty) : [:]
        return try? Engine.frameLayout(frame: spec, photoWidth: size.width, photoHeight: size.height)
    }

    func adjust(_ key: String, to value: Double) {
        guard value.isFinite, adjustments[key] != value, let photo, hasEditedFrame,
              document?.phase == .ready else { return }
        adjustments[key] = value
        operation?.cancel()
        generation += 1
        let ticket = generation
        document?.isRefreshing = true
        document?.previewError = nil
        operation = Task { [weak self, services, adjustments] in
            for await event in services.previews(for: photo, includingReference: false, adjustments: adjustments) {
                guard let self, generation == ticket, !Task.isCancelled else { return }
                apply(event)
            }
            guard let self, generation == ticket, !Task.isCancelled else { return }
            operation = nil
        }
    }

    private func apply(_ event: EditorPreviewEvent) {
        switch event {
        case .reference(let frame):
            hasReferenceFrame = true
            hasEditedFrame = false
            selectedMode = .edited
            editedGainWeight = nil
            display.gainWeight = nil
            document?.pixelSize = frame.pixelSize
            document?.source = frame.source
            canvas.setImageSize(frame.pixelSize)
        case .edited(let frame):
            hasEditedFrame = true
            document?.pixelSize = frame.pixelSize
            document?.phase = .ready
            document?.isRefreshing = false
            document?.previewError = nil
            canvas.setImageSize(frame.pixelSize, zoom: canvas.zoom)
            editedGainWeight = frame.hasGain ? services.displayState.gainWeight ?? 1 : nil
            display.gainWeight = selectedMode == .edited ? editedGainWeight : nil
        case .failed(let error):
            document?.isRefreshing = false
            document?.previewError = error
        }
    }

    var hasPreviewFrame: Bool {
        // Until the new edit arrives, its reference SDR base is the fallback.
        hasReferenceFrame || hasEditedFrame
    }

    func receiveDisplay(_ state: DisplayState) {
        pendingDisplay = state
        guard displayPublication == nil else { return }
        displayPublication = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, let state = pendingDisplay else { return }
            display = state
            if hasEditedFrame, selectedMode == .edited { editedGainWeight = state.gainWeight }
            display.gainWeight = hasEditedFrame && selectedMode == .edited ? editedGainWeight : nil
            pendingDisplay = nil
            displayPublication = nil
        }
    }

    func reportCanvasFailure(_ detail: String) {
        guard document != nil else { return }
        // Invalidate both opening and refresh work so a late edited frame
        // cannot replace the renderer failure with a ready document.
        generation += 1
        operation?.cancel()
        operation = nil
        let error = UserFacingError(code: "metal_unavailable", detail: detail)
        if let previous = openRollback {
            restore(previous, error: error)
        } else {
            // An opened document with no drawable frame uses .failed. Opening
            // a replacement instead follows Q14's rollback path above.
            document?.phase = .failed(error)
            document?.isRefreshing = false
            hasReferenceFrame = false
            hasEditedFrame = false
            editedGainWeight = nil
            display.gainWeight = nil
            canvas.setImageSize(nil)
        }
    }

    private func restore(_ previous: OpenSnapshot, error: UserFacingError) {
        document = previous.document
        photo = previous.photo
        hasReferenceFrame = previous.reference
        hasEditedFrame = previous.edited
        selectedMode = previous.viewMode
        display = previous.display
        editedGainWeight = previous.editedGainWeight
        canvas.setImageSize(previous.reference || previous.edited ? previous.document?.pixelSize : nil,
                            zoom: previous.zoom)
        workspace = document == nil ? .empty : .editing
        alert = error
        openRollback = nil
    }
}
