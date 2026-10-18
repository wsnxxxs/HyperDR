import Foundation
import HyperDREngine
import HyperDRKit
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
    var frame: FrameSettings {
        didSet { if frame != oldValue { frame.save(to: services.preferences) } }
    }
    /// The committed photograph's Exif, loaded automatically in the background.
    private(set) var captureFacts = CaptureFacts()

    private var selectedMode: ViewMode = .edited
    private(set) var hasReferenceFrame: Bool
    private(set) var hasEditedFrame: Bool
    @ObservationIgnored private let services: any EditorServices
    @ObservationIgnored private var photo: EditorPhoto?
    @ObservationIgnored private var adjustments: [String: Double] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var captureFactsTask: Task<Void, Never>?
    @ObservationIgnored private var displayObserver: Task<Void, Never>?
    @ObservationIgnored private var displayPublication: Task<Void, Never>?
    @ObservationIgnored private var pendingDisplay: DisplayState?
    @ObservationIgnored private var openRollback: OpenSnapshot?
    @ObservationIgnored private var editedGainWeight: Double?

    private(set) var frameRevision: UInt64 = 0
    @ObservationIgnored private var referenceFrame: PreviewFrame?
    @ObservationIgnored private var editedFrame: PreviewFrame?
    @ObservationIgnored private var engineObserver: Task<Void, Never>?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var canRestoreAtLaunch = true
    @ObservationIgnored private var refreshObserver: Task<Void, Never>?
    @ObservationIgnored private var renderScheduler: RenderScheduler<[String: Double]>?
    @ObservationIgnored private let ticker: any FrameTicker
    @ObservationIgnored private var submittedEdge = 2048

    private struct OpenSnapshot {
        var document: DocumentState?
        let photo: EditorPhoto?
        let reference: Bool
        let edited: Bool
        let viewMode: ViewMode
        let transform: CanvasTransform
        let adjustments: [String: Double]
        let needsRefresh: Bool
        let display: DisplayState
        let editedGainWeight: Double?
        let referenceFrame: PreviewFrame?
        let editedFrame: PreviewFrame?
        let captureFacts: CaptureFacts
    }

    init(services: any EditorServices = FakeEditorServices(), document: DocumentState? = nil,
         alert: UserFacingError? = nil, photo: EditorPhoto? = nil,
         hasReferenceFrame: Bool = false, hasEditedFrame: Bool = false, ticker: (any FrameTicker)? = nil) {
        self.services = services
        self.ticker = ticker ?? ClockFrameTicker()
        frame = FrameSettings.load(from: services.preferences)
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
        let statuses = services.engineUpdates()
        engineObserver = Task { [weak self] in
            for await status in statuses {
                guard !Task.isCancelled else { return }
                self?.engine = status
            }
        }
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
        captureFactsTask?.cancel()
        launchTask?.cancel()
        engineObserver?.cancel()
        refreshObserver?.cancel()
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
        canRestoreAtLaunch = false
        beginOpen(urls)
    }

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        let ticket = generation
        launchTask = Task { [weak self, services] in
            await services.start()
            guard let self, !Task.isCancelled, generation == ticket,
                  canRestoreAtLaunch, document == nil, openRollback == nil, photo == nil else { return }
            let result = await services.restoreLast()
            guard !Task.isCancelled, generation == ticket, canRestoreAtLaunch,
                  document == nil, openRollback == nil, photo == nil else {
                if case .restored(let photo) = result { await services.close(photo) }
                return
            }
            switch result {
            case .none: break
            case .unavailable(let error): alert = error
            case .restored(let photo): beginOpen([photo.url], restored: photo)
            }
        }
    }

    func report(openFailure error: any Error) { alert = UserFacingError.importFailure(error) }

    private func beginOpen(_ urls: [URL], restored: EditorPhoto? = nil) {
        if case .failed(let error) = engine {
            alert = UserFacingError(code: "engine_unavailable", detail: error.detail)
            return
        }
        guard let url = urls.first(where: canOpen) else {
            alert = UserFacingError(code: "unsupported_format")
            return
        }

        operation?.cancel()
        captureFactsTask?.cancel()
        generation += 1
        let ticket = generation
        var previous = openRollback ?? OpenSnapshot(document: document, photo: photo,
            reference: hasReferenceFrame, edited: hasEditedFrame, viewMode: selectedMode,
            transform: canvas.transform, adjustments: adjustments,
            needsRefresh: document?.isRefreshing == true || renderScheduler?.hasPending == true,
            display: display, editedGainWeight: editedGainWeight,
            referenceFrame: referenceFrame, editedFrame: editedFrame, captureFacts: captureFacts)
        stopRefreshing()
        previous.document?.isRefreshing = false
        openRollback = previous
        document = services.placeholder(for: url).openingDocument
        workspace = .editing
        alert = nil

        operation = Task { [weak self, services] in
            guard let self else { return }
            var candidate: EditorPhoto?
            do {
                let opened: EditorPhoto
                if let restored { opened = restored }
                else { opened = try await services.open(url) }
                candidate = opened
                try Task.checkCancellation()
                guard generation == ticket else { await services.close(opened); return }
                document = opened.openingDocument
                document?.phase = .rendering
                for await event in services.previews(for: opened, includingReference: true, adjustments: [:], maxEdge: previewEdge) {
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
                        startCaptureFacts(opened)
                        startRefreshing(opened)
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
        canRestoreAtLaunch = false
        generation += 1
        operation?.cancel()
        captureFactsTask?.cancel()
        operation = nil
        stopRefreshing()
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
        referenceFrame = nil
        editedFrame = nil
        frameRevision &+= 1
        canvas.setImageSize(nil)
    }

    func dismissAlert() { alert = nil }

    // MARK: Frame

    private func startCaptureFacts(_ photo: EditorPhoto) {
        captureFactsTask?.cancel()
        let ticket = generation
        captureFactsTask = Task { [weak self, services] in
            let facts = await services.captureFacts(for: photo)
            guard let self, !Task.isCancelled, generation == ticket,
                  self.photo == photo else { return }
            captureFacts = facts
        }
    }

    /// The caption the frame sets for this photograph.
    var frameCaption: FrameCaption { frame.style.caption(frame, facts: captureFacts) }

    var canvasFrame: PreviewCanvasFrame? {
        if selectedMode == .original, let referenceFrame {
            return PreviewCanvasFrame(frame: referenceFrame, showsOriginal: true)
        }
        if let editedFrame { return PreviewCanvasFrame(frame: editedFrame, showsOriginal: false) }
        return referenceFrame.map { PreviewCanvasFrame(frame: $0, showsOriginal: true) }
    }

    var editedCanvasFrame: PreviewCanvasFrame? {
        (editedFrame ?? referenceFrame).map { PreviewCanvasFrame(frame: $0, showsOriginal: false) }
    }

    private var previewEdge: Int {
        let transform = canvas.transform
        guard transform.viewport.width > 0, transform.viewport.height > 0 else { return 2048 }
        return EditDefaults.previewEdge(ceiling: 2048, boxWidth: transform.viewport.width,
            boxHeight: transform.viewport.height, scale: transform.backingScale)
    }

    func updateViewport(_ size: CGSize, backingScale: Double) {
        canvas.setViewport(size, backingScale: backingScale)
        guard document?.phase == .ready, submittedEdge != previewEdge else { return }
        setRefreshing(true)
        renderScheduler?.update(adjustments)
    }

    func updateRefreshRate(_ framesPerSecond: Int) {
        (ticker as? ClockFrameTicker)?.framesPerSecond = framesPerSecond
    }

    func adjust(_ key: String, to value: Double) {
        guard value.isFinite, adjustments[key] != value, photo != nil, hasEditedFrame,
              document?.phase == .ready else { return }
        adjustments[key] = value
        setRefreshing(true)
        if document?.previewError != nil { document?.previewError = nil }
        renderScheduler?.update(adjustments)
    }

    private func setRefreshing(_ refreshing: Bool) {
        if document?.isRefreshing != refreshing { document?.isRefreshing = refreshing }
    }

    private func stopRefreshing() {
        refreshObserver?.cancel()
        refreshObserver = nil
        renderScheduler?.cancel()
        renderScheduler = nil
    }

    private func startRefreshing(_ photo: EditorPhoto) {
        stopRefreshing()
        let ticket = generation
        submittedEdge = previewEdge
        let initialUpdates = services.refreshes(for: photo)
        refreshObserver = Task { [weak self, services] in
            var updates = initialUpdates
            while !Task.isCancelled {
                var restart = false
                for await event in updates {
                    guard !Task.isCancelled, let self, generation == ticket, self.photo == photo,
                          document?.phase == .ready else { return }
                    switch event {
                    case .edited(let preview, let isLatest):
                        apply(.edited(preview), finishesRefresh: isLatest && renderScheduler?.hasPending != true)
                    case .failed(let error):
                        if renderScheduler?.hasPending != true { apply(.failed(error)) }
                    case .superseded(let isLatest):
                        guard isLatest else { continue }
                        if renderScheduler?.hasPending != true { setRefreshing(false) }
                        restart = true
                    case .sourceReplaced:
                        open([photo.url])
                        return
                    }
                    if restart { break }
                }
                guard !Task.isCancelled, self?.generation == ticket, self?.photo == photo,
                      self?.document?.phase == .ready else { return }
                if self?.renderScheduler?.hasPending != true { self?.setRefreshing(false) }
                // Subscribe before awaiting so edits during the retry delay are
                // buffered. One resident loop backs off from repeatedly empty streams.
                updates = services.refreshes(for: photo)
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard self?.generation == ticket, self?.photo == photo else { return }
            }
        }
        renderScheduler = RenderScheduler(ticker: ticker) { [weak self] values in
            guard let self, generation == ticket, self.photo == photo, document?.phase == .ready else { return }
            submittedEdge = previewEdge
            setRefreshing(true)
            services.submit(photo, adjustments: values, maxEdge: submittedEdge)
        }
    }

    private func apply(_ event: EditorPreviewEvent, finishesRefresh: Bool = true) {
        switch event {
        case .reference(let frame):
            referenceFrame = frame.frame
            editedFrame = nil
            frameRevision &+= 1
            hasReferenceFrame = true
            hasEditedFrame = false
            selectedMode = .edited
            editedGainWeight = nil
            display.gainWeight = nil
            document?.pixelSize = frame.pixelSize
            document?.source = frame.source
            canvas.setImageSize(frame.pixelSize)
        case .edited(let frame):
            editedFrame = frame.frame
            frameRevision &+= 1
            hasEditedFrame = true
            document?.pixelSize = frame.pixelSize
            document?.phase = .ready
            if finishesRefresh { setRefreshing(false) }
            document?.previewError = nil
            canvas.setImageSize(frame.pixelSize, zoom: canvas.zoom)
            editedGainWeight = frame.hasGain ? frame.gainWeight ?? services.displayState.gainWeight ?? 1 : nil
            display.gainWeight = selectedMode == .edited ? editedGainWeight : nil
        case .failed(let error):
            setRefreshing(false)
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
        captureFactsTask?.cancel()
        operation = nil
        stopRefreshing()
        let error = UserFacingError(code: "metal_unavailable", detail: detail)
        if let previous = openRollback {
            restore(previous, error: error)
        } else {
            // An opened document with no drawable frame uses .failed. Opening
            // a replacement instead follows Q14's rollback path above.
            document?.phase = .failed(error)
            setRefreshing(false)
            referenceFrame = nil
            editedFrame = nil
            frameRevision &+= 1
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
        adjustments = previous.adjustments
        hasReferenceFrame = previous.reference
        hasEditedFrame = previous.edited
        selectedMode = previous.viewMode
        display = previous.display
        editedGainWeight = previous.editedGainWeight
        referenceFrame = previous.referenceFrame
        editedFrame = previous.editedFrame
        captureFacts = previous.captureFacts
        frameRevision &+= 1
        canvas.setImageSize(previous.reference || previous.edited ? previous.document?.pixelSize : nil,
                            zoom: previous.transform.zoom <= CanvasTransform.minZoom ? .fit : .scale(previous.transform.zoom))
        var transform = canvas.transform
        transform.pan = transform.clampedPan(previous.transform.pan)
        canvas.apply(transform)
        workspace = document == nil ? .empty : .editing
        alert = error
        openRollback = nil
        if let photo {
            startCaptureFacts(photo)
            startRefreshing(photo)
            if previous.needsRefresh {
                setRefreshing(true)
                renderScheduler?.update(adjustments)
            }
        }
    }
}
