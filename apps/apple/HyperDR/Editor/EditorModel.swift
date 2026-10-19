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
    /// Counts the photos committed to the canvas, so the views can tell a new
    /// photo from the old one even when the new one has the same name.
    private(set) var photoSerial = 0
    private(set) var hasReferenceFrame: Bool
    private(set) var hasEditedFrame: Bool
    @ObservationIgnored let services: any EditorServices
    @ObservationIgnored var photo: EditorPhoto?
    @ObservationIgnored var generation = 0

    // MARK: Editing state (EditorModel+Editing.swift)
    /// The values every request is built from.
    @ObservationIgnored var edit: EditSnapshot
    /// What the photo was opened with, for the current encoding's defaults.
    @ObservationIgnored var source = PhotoSource()
    @ObservationIgnored var controlValues: [String: ControlValue] = [:]
    let inputColor: ChoiceValue<String>
    let ai = AIState()
    let scopes = ScopeState()
    private(set) var workflow: Workflow = .hdr
    /// A one-shot message shown in place; the view clears it.
    var notice: EditorNotice?
    /// Bumped whenever the undo stack changes, so menu items re-evaluate.
    private(set) var undoRevision: UInt64 = 0
    /// Editor history never shares policy or registrations with AppKit text.
    @ObservationIgnored let undoManager = UndoManager()
    private(set) var isRestoring = false
    /// The control being dragged and the values when the drag began.
    @ObservationIgnored var gesture: (key: String, start: EditSnapshot)?
    /// The encoding the next photo opens with; kept for this run.
    @ObservationIgnored var runEncoding = "adaptive"
    @ObservationIgnored var remembered = RememberedHDR()
    @ObservationIgnored var lastJob: RenderJob?

    // MARK: AI state (EditorModel+AI.swift)
    @ObservationIgnored var gainToken: ModelGainToken?
    @ObservationIgnored var readyGain: ModelGainToken?
    @ObservationIgnored var aiTask: Task<Void, Never>?
    @ObservationIgnored var tokenTask: Task<Void, Never>?
    @ObservationIgnored var aiTicket = 0
    /// Why the last AI computation failed; AI stays unavailable until the
    /// inputs or the photo change.
    @ObservationIgnored var aiFailureReason: String?

    // MARK: Viewer state (EditorModel+Viewer.swift)
    private(set) var splitRatio = 0.5
    private(set) var isPeekingOriginal = false
    @ObservationIgnored var scopeTask: Task<Void, Never>?
    @ObservationIgnored var originalScopeTask: Task<Void, Never>?

    func setSplitRatioValue(_ value: Double) { if value != splitRatio { splitRatio = value } }
    func setPeeking(_ value: Bool) { if value != isPeekingOriginal { isPeekingOriginal = value } }
    func setWorkflowValue(_ value: Workflow) { if value != workflow { workflow = value } }
    func bumpFrameRevision() { frameRevision &+= 1 }
    func clearPreviewError() { if document?.previewError != nil { document?.previewError = nil } }
    func bumpUndoRevision() { undoRevision &+= 1 }
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
    @ObservationIgnored var renderScheduler: RenderScheduler<RenderJob>?
    @ObservationIgnored private let ticker: any FrameTicker
    @ObservationIgnored private var submittedEdge = 2048
    @ObservationIgnored var lastSubmitWasDraft = false
    @ObservationIgnored var submittedJob: RenderJob?
    @ObservationIgnored var displayedAIGain: ModelGainToken?
    @ObservationIgnored private var busyTask: Task<Void, Never>?
    @ObservationIgnored var renderOutstanding = false
    @ObservationIgnored var referenceOptions: EditOptions?
    @ObservationIgnored var detailTask: Task<Void, Never>?
    @ObservationIgnored var detailTicket = 0
    @ObservationIgnored var editedDetailFrame: PreviewFrame?
    @ObservationIgnored var originalDetailFrame: PreviewFrame?
    private(set) var maskKey: String?
    func setMaskKey(_ value: String?) { maskKey = value }
    var showsHighlightZebra = false { didSet { if showsHighlightZebra != oldValue { bumpFrameRevision() } } }
    var showsShadowZebra = false { didSet { if showsShadowZebra != oldValue { bumpFrameRevision() } } }
    var previewsAsSDR = false { didSet { if previewsAsSDR != oldValue { bumpFrameRevision() } } }

    private struct OpenSnapshot {
        var document: DocumentState?
        let photo: EditorPhoto?
        let reference: Bool
        let edited: Bool
        let viewMode: ViewMode
        let transform: CanvasTransform
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
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 0
        self.ticker = ticker ?? ClockFrameTicker()
        let initial = EditDefaults.initial(encoding: "adaptive", sourceDomain: nil, unadjusted: nil)
        edit = EditSnapshot(initial)
        let colors = EditChoices.byKey["colorGamut"]?.options ?? []
        inputColor = ChoiceValue(key: "colorGamut", selection: edit.choices["colorGamut"] ?? "srgb",
            choices: colors.map { Choice(id: $0.id, labelKey: $0.labelKey, isEnabled: true) })
        for spec in EditControls.all { controlValues[spec.key] = ControlValue(spec: ControlSpecView(spec)) }
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
        source.domain = document?.source?.domain
        syncControls()
        canvas.onGeometryChange = { [weak self] in self?.canvasGeometryChanged() }
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
        detailTask?.cancel()
        busyTask?.cancel()
        aiTask?.cancel()
        tokenTask?.cancel()
        scopeTask?.cancel()
        originalScopeTask?.cancel()
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
            scheduleDetails()
            display.gainWeight = newValue != .original ? editedGainWeight : nil
        }
    }

    var openableContentTypes: [UTType] { services.openableContentTypes }
    func canOpen(_ url: URL) -> Bool { services.canOpen(url) }

    func isAvailable(_ mode: ViewMode) -> Bool {
        switch mode {
        case .original: hasReferenceFrame
        case .edited: hasEditedFrame
        case .compare: hasReferenceFrame && hasEditedFrame
        }
    }

    /// Q14: document describes the new source immediately, but the previous
    /// frames, mode and canvas geometry stay visible until its reference arrives.
    /// Any open failure restores the complete previous state, or the empty state.
    func open(_ urls: [URL]) {
        guard !ai.isComputing else { return }
        canRestoreAtLaunch = false
        isRestoring = false
        beginOpen(urls)
    }

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        isRestoring = canRestoreAtLaunch && document == nil && photo == nil && openRollback == nil
        let ticket = generation
        launchTask = Task { [weak self, services] in
            defer { if self?.generation == ticket { self?.isRestoring = false } }
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
        isRestoring = false
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
        invalidateDetails()
        cancelAI()
        endGesture()
        generation += 1
        let ticket = generation
        let encoding = runEncoding
        var previous = openRollback ?? OpenSnapshot(document: document, photo: photo,
            reference: hasReferenceFrame, edited: hasEditedFrame, viewMode: selectedMode,
            transform: canvas.transform,
            needsRefresh: renderOutstanding || document?.isRefreshing == true || renderScheduler?.hasPending == true,
            display: display, editedGainWeight: editedGainWeight,
            referenceFrame: referenceFrame, editedFrame: editedFrame, captureFacts: captureFacts)
        stopRefreshing()
        previous.document?.isRefreshing = false
        openRollback = previous
        document = services.placeholder(for: url).openingDocument
        workspace = .editing
        alert = nil
        syncControls()

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
                var reference: EditorPreview?
                for await event in services.previews(for: opened, encoding: encoding, maxEdge: previewEdge) {
                    try Task.checkCancellation()
                    guard generation == ticket else { throw CancellationError() }
                    if case .failed(let error) = event { throw error }
                    if case .reference(let preview) = event { reference = preview }
                    if case .edited(let preview) = event {
                        // Commit the opened photo before publishing ready. A new
                        // refresh or open may start before the stream ends.
                        photo = opened
                        photoSerial += 1
                        captureFacts = CaptureFacts()
                        openRollback = nil
                        operation = nil
                        beginEditing(encoding: encoding, reference: reference ?? preview)
                        apply(event)
                        startScopes(original: true)
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
        isRestoring = false
        generation += 1
        operation?.cancel()
        captureFactsTask?.cancel()
        operation = nil
        stopRefreshing()
        if let photo { Task { [services] in await services.close(photo) } }
        photo = nil
        invalidateDetails()
        openRollback = nil
        document = nil
        workspace = .empty
        alert = nil
        hasReferenceFrame = false
        hasEditedFrame = false
        selectedMode = .edited
        captureFacts = CaptureFacts()
        cancelAI()
        endGesture()
        endEditing()
        display.gainWeight = nil
        editedGainWeight = nil
        referenceFrame = nil
        editedFrame = nil
        frameRevision &+= 1
        canvas.setImageSize(nil)
        syncControls()
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
        if selectedMode == .original || isPeekingOriginal, let referenceFrame {
            return PreviewCanvasFrame(frame: referenceFrame, showsOriginal: true)
        }
        if let editedFrame { return PreviewCanvasFrame(frame: editedFrame, showsOriginal: false) }
        return referenceFrame.map { PreviewCanvasFrame(frame: $0, showsOriginal: true) }
    }

    var editedCanvasFrame: PreviewCanvasFrame? {
        (editedFrame ?? referenceFrame).map { PreviewCanvasFrame(frame: $0, showsOriginal: false) }
    }

    /// The original side of the split view (renderer, M2-R).
    var originalCanvasFrame: PreviewCanvasFrame? {
        referenceFrame.map { PreviewCanvasFrame(frame: $0, showsOriginal: true) }
    }

    /// Frames for the scope analyser.
    var currentEditedFrame: PreviewFrame? { editedFrame }
    var currentReferenceFrame: PreviewFrame? { referenceFrame }

    var previewEdge: Int {
        let transform = canvas.transform
        guard transform.viewport.width > 0, transform.viewport.height > 0 else { return 2048 }
        return EditDefaults.previewEdge(ceiling: 2048, boxWidth: transform.viewport.width,
            boxHeight: transform.viewport.height, scale: transform.backingScale)
    }

    func updateViewport(_ size: CGSize, backingScale: Double) {
        canvas.setViewport(size, backingScale: backingScale)
        guard document?.phase == .ready, submittedEdge != previewEdge else { return }
        scheduleRender(force: true)
    }

    func updateRefreshRate(_ framesPerSecond: Int) {
        (ticker as? ClockFrameTicker)?.framesPerSecond = framesPerSecond
    }

    /// The latest adjustment starts a fresh 300 ms grace period. Fast frames
    /// never publish busy; an already-visible busy indicator stays until a frame.
    func requestBusy() {
        renderOutstanding = true
        busyTask?.cancel()
        guard document?.isRefreshing != true else { busyTask = nil; return }
        busyTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !Task.isCancelled, renderOutstanding else { return }
            if document?.isRefreshing != true { document?.isRefreshing = true }
            busyTask = nil
        }
    }

    func setRefreshing(_ refreshing: Bool) {
        if !refreshing {
            busyTask?.cancel()
            busyTask = nil
            renderOutstanding = false
        }
        if document?.isRefreshing != refreshing { document?.isRefreshing = refreshing }
    }

    private func stopRefreshing() {
        setRefreshing(false)
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
                        let final = isLatest && renderScheduler?.hasPending != true
                        apply(.edited(preview), finishesRefresh: final)
                        if final {
                            displayedAIGain = submittedJob?.options["useModel"] == .bool(true) ? readyGain : nil
                            updateAIState()
                            if !lastSubmitWasDraft {
                                startScopes(original: false)
                                scheduleDetails()
                            }
                        }
                    case .failed(let error):
                        if renderScheduler?.hasPending != true {
                            apply(.failed(error))
                            if edit.aiMode == .optimized, !ai.isComputing,
                               submittedJob?.options == edit.options() { failAI(error) }
                        }
                    case .superseded(let isLatest):
                        guard isLatest else { continue }
                        if renderScheduler?.hasPending != true { setRefreshing(false) }
                        restart = true
                    case .sourceReplaced:
                        cancelAI()
                        readyGain = nil
                        gainToken = nil
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
        renderScheduler = RenderScheduler(ticker: ticker) { [weak self] job in
            guard let self, generation == ticket, self.photo == photo, document?.phase == .ready else { return }
            guard !ai.isComputing else { return }
            submittedJob = job
            submittedEdge = job.draft ? Self.draftEdge : previewEdge
            lastSubmitWasDraft = job.draft
            services.submit(photo, options: job.options, maxEdge: submittedEdge)
        }
    }

    func apply(_ event: EditorPreviewEvent, finishesRefresh: Bool = true) {
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
            setPeeking(false)
        case .edited(let frame):
            editedFrame = frame.frame
            canvas.previewPixelSize = frame.frame.map { CGSize(width: $0.base.width, height: $0.base.height) }
            frameRevision &+= 1
            hasEditedFrame = true
            document?.pixelSize = frame.pixelSize
            document?.phase = .ready
            if finishesRefresh { setRefreshing(false) }
            document?.previewError = nil
            canvas.setImageSize(frame.pixelSize, zoom: canvas.zoom)
            editedGainWeight = frame.hasGain ? frame.gainWeight ?? services.displayState.gainWeight ?? 1 : nil
            display.gainWeight = selectedMode != .original ? editedGainWeight : nil
        case .failed(let error):
            setRefreshing(false)
            document?.previewError = error
        }
        syncControls()
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
            if hasEditedFrame, selectedMode != .original { editedGainWeight = state.gainWeight }
            display.gainWeight = hasEditedFrame && selectedMode != .original ? editedGainWeight : nil
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
        cancelAI()
        endGesture()
        operation = nil
        stopRefreshing()
        invalidateDetails()
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
            syncControls()
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
        clearUndo()
        if photo == nil { endEditing() }
        syncControls()
        if let photo {
            startCaptureFacts(photo)
            startRefreshing(photo)
            if previous.needsRefresh { scheduleRender(force: true) }
            revalidateGain()
        }
    }
}
