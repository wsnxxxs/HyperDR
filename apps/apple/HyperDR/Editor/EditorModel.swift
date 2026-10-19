import AppKit
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
    @ObservationIgnored private var storedFrame: FrameSettings
    var frame: FrameSettings {
        get { _ = frameSettingsRevision; return storedFrame }
        set {
            guard !export.isInFlight, newValue != storedFrame else { return }
            storedFrame = newValue; frameSettingsRevision &+= 1
            pendingExportToken = nil
            newValue.save(to: services.preferences)
            syncExportState(); refreshExportMetadata()
            if !thumbnailTrackers.isEmpty { updateSummaryThumbnail() }
        }
    }
    private(set) var frameSettingsRevision = 0
    let export = ExportState()
    let lut = LUTState()
    let preferences: PreferencesState
    var exportVersions: [ExportVersion] = []
    var exportSaveStates: [String: ExportSaveState] = [:]
    var pendingPhotoSwitch: PhotoSwitchRequest?
    var suggestedFileName = ""
    @ObservationIgnored var cachedFrameKey: ExportFrameCacheKey?
    @ObservationIgnored var cachedExportFrame: ExportFrame?
    var exportSummaryThumbnail: ThumbnailState = .unavailable
    var versionThumbnails: [String: ThumbnailState] = [:]
    @ObservationIgnored var thumbnailTrackers: Set<UUID> = []
    @ObservationIgnored var summaryThumbnailTask: Task<Void, Never>?
    @ObservationIgnored var summaryThumbnailTicket = 0
    @ObservationIgnored var summaryThumbnailLastStart: ContinuousClock.Instant?
    @ObservationIgnored var summaryThumbnailFrame: PreviewFrame?
    @ObservationIgnored var deferredExportThumbnailTask: Task<Void, Never>?
    @ObservationIgnored var exportThumbnailEditGeneration: Int?
    @ObservationIgnored var exportThumbnailNeedsDeferred = false
    /// The frame the running (or just finished) export carries, for a thumbnail that arrives late.
    @ObservationIgnored var exportThumbnailFraming: ThumbnailFraming?
    @ObservationIgnored var exportThumbnailPersisted = false
    @ObservationIgnored var versionThumbnailTask: Task<Void, Never>?
    @ObservationIgnored var versionThumbnailQueue: [String] = []
    @ObservationIgnored var versionThumbnailOrder: [String] = []
    @ObservationIgnored var thumbnailEpoch = 0
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored var saveTaskNames: [UUID: String] = [:]
    @ObservationIgnored var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var exportMetadataTask: Task<Void, Never>?
    @ObservationIgnored var exportMetadataTicket = 0
    @ObservationIgnored var exportHistory: [ExportHistoryItem] = []
    @ObservationIgnored var timingHistory: [ExportTimingSample] = []
    @ObservationIgnored var currentExportKey: String?
    @ObservationIgnored var exportCapabilities: EditorCapabilities?
    @ObservationIgnored var pendingSwitchStops = false
    @ObservationIgnored var lutLibraryReadSequence = 0
    @ObservationIgnored var lutLibraryAcceptedSequence = 0
    @ObservationIgnored var lutMetadataTask: Task<Void, Never>?
    @ObservationIgnored var lutMetadataWrites: [String: LUTMetadataWrite] = [:]
    @ObservationIgnored var lutTask: Task<Void, Never>?
    @ObservationIgnored var lutTicket = 0
    @ObservationIgnored let now: () -> Date

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
    @ObservationIgnored var edit: EditSnapshot {
        didSet {
            if oldValue != edit { editGeneration &+= 1; pendingExportToken = nil }
        }
    }
    @ObservationIgnored var editGeneration = 0
    @ObservationIgnored var pendingExportToken: UUID?
    /// What the photo was opened with, for the current encoding's defaults.
    @ObservationIgnored var source = PhotoSource()
    @ObservationIgnored var controlValues: [String: ControlValue] = [:]
    let inputColor: ChoiceValue<String>
    let ai = AIState()
    let scopes = ScopeState()
    private(set) var workflow: Workflow = .hdr
    /// A one-shot message shown in place; the view clears it.
    var notice: EditorNotice?
    /// What the canvas says about the photo that was reopened at launch, or
    /// about the one it could not find (parity batch 7 §2).
    var restoreNotice: RestoreNotice?
    /// A reopened photo waits for its first export-history refresh before it
    /// says so, so the sentence is not changed after it appears.
    @ObservationIgnored var restoreNoticePending = false
    @ObservationIgnored var restoreNoticeTask: Task<Void, Never>?
    /// Set while the photo's file cannot be found; only for `source_missing`.
    var sourceUnavailable: UserFacingError?
    /// The name of a photo that was read again after another app changed its
    /// file; shown as a chip over the canvas.
    var sourceReplacedNotice: String?
    @ObservationIgnored var sourceRetryTask: Task<Void, Never>?
    @ObservationIgnored var sourceActivationObserver: (any NSObjectProtocol)?
    @ObservationIgnored var sourceRetryInterval: Duration = .seconds(30)
    /// Whether the app is in front: the timer retries only then.
    @ObservationIgnored var appIsActive: () -> Bool = { NSApplication.shared.isActive }
    @ObservationIgnored var isRetryingSource = false
    @ObservationIgnored var locateTask: Task<Void, Never>?
    /// A chosen file is being checked against the photo (its content is read
    /// to be sure it is the same one).
    var isRelinking = false
    @ObservationIgnored var replacedAwaitingExport: EditorPhoto?
    /// Bumped whenever the undo stack changes, so menu items re-evaluate.
    private(set) var undoRevision: UInt64 = 0
    /// Editor history never shares policy or registrations with AppKit text.
    @ObservationIgnored let undoManager = UndoManager()
    private(set) var isRestoring = false
    /// The deadline passed while the last photo was still being found (a
    /// bookmark on a network volume, say): there is no document yet to carry
    /// `isOpeningSlowly`, and the canvas offers to cancel all the same.
    private var restoreIsSlow = false
    var isRestoringSlowly: Bool { isRestoring && restoreIsSlow }
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
    @ObservationIgnored private var cameraSupportTask: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var captureFactsTask: Task<Void, Never>?
    @ObservationIgnored private var displayObserver: Task<Void, Never>?
    @ObservationIgnored private var displayPublication: Task<Void, Never>?
    @ObservationIgnored private var pendingDisplay: DisplayState?
    private var openRollback: OpenSnapshot?
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
    /// The options the "original" frame on screen was rendered with; the
    /// original details always use `referenceOptions`, which only differs
    /// while a new original is rendering.
    @ObservationIgnored var shownReferenceOptions: EditOptions?
    @ObservationIgnored var referenceRefreshTask: Task<Void, Never>?
    @ObservationIgnored var detailTask: Task<Void, Never>?
    @ObservationIgnored var detailTicket = 0
    @ObservationIgnored var originalDetailTrace: PreviewTrace?
    @ObservationIgnored var editedDetailTrace: PreviewTrace?
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
         hasReferenceFrame: Bool = false, hasEditedFrame: Bool = false, ticker: (any FrameTicker)? = nil, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.now = now
        preferences = PreferencesState(Preferences.load(from: services.preferences))
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 0
        self.ticker = ticker ?? ClockFrameTicker()
        let initial = EditDefaults.initial(encoding: "adaptive", sourceDomain: nil, unadjusted: nil)
        edit = EditSnapshot(initial)
        let colors = EditChoices.byKey["colorGamut"]?.options ?? []
        inputColor = ChoiceValue(key: "colorGamut", selection: edit.choices["colorGamut"] ?? "srgb",
            choices: colors.map { Choice(id: $0.id, labelKey: $0.labelKey, isEnabled: true) })
        for spec in EditControls.all { controlValues[spec.key] = ControlValue(spec: ControlSpecView(spec)) }
        storedFrame = FrameSettings.load(from: services.preferences)
        engine = services.engineStatus
        display = services.displayState
        if preferences.value.rememberOutput { runEncoding = preferences.value.output["encoding"] ?? "adaptive" }
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
                self?.syncExportState()
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
        summaryThumbnailTask?.cancel(); deferredExportThumbnailTask?.cancel(); versionThumbnailTask?.cancel()
        exportTask?.cancel()
        exportMetadataTask?.cancel()
        lutTask?.cancel()
        lutMetadataTask?.cancel()
        for write in lutMetadataWrites.values { write.task?.cancel() }
        for task in saveTasks.values { task.cancel() }
        cameraSupportTask?.cancel()
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
    func open(_ urls: [URL], afterReplacement replacedName: String? = nil) {
        if export.isInFlight {
            guard let url = urls.first(where: canOpen) else { return }
            pendingPhotoSwitch = PhotoSwitchRequest(kind: .open(url), displayName: url.lastPathComponent)
            return
        }
        guard !ai.isComputing else { return }
        canRestoreAtLaunch = false
        isRestoring = false
        prepareForPhotoSwitch()
        beginOpen(urls, replacedName: replacedName)
    }

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        Task { [weak self] in await self?.loadExportServices() }
        isRestoring = canRestoreAtLaunch && document == nil && photo == nil && openRollback == nil
        syncControls()
        let ticket = generation
        let openedAt = services.openClock.now
        if isRestoring { startCameraSupportDeadline(openedAt: openedAt, ticket: ticket) }
        launchTask = Task { [weak self, services] in
            defer {
                if self?.generation == ticket {
                    self?.cameraSupportTask?.cancel()
                    self?.isRestoring = false
                    self?.syncControls()
                }
            }
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
            case .unavailable(let error, let name):
                // The photo is gone: say so where the picker is, not in a
                // dialog nobody asked for. Other failures keep the alert.
                if error.code == "source_missing" || error.code == "session_expired" {
                    restoreNotice = .missing(name: name)
                    // Once, here: a view that is rebuilt later must not read it again.
                    NoticeAnnouncement.post(RestoreMissingNotice.announcement(name: name, locale: .current), highPriority: true)
                }
                else { alert = error }
            case .restored(let photo): beginOpen([photo.url], restored: photo, openedAt: openedAt)
            }
        }
    }

    func report(openFailure error: any Error) { alert = UserFacingError.importFailure(error) }

    private func beginOpen(_ urls: [URL], restored: EditorPhoto? = nil, openedAt: Duration? = nil, replacedName: String? = nil) {
        isRestoring = false
        clearRestoreNotice()
        if case .failed(let error) = engine {
            alert = UserFacingError(code: "engine_unavailable", detail: error.detail)
            return
        }
        guard let url = urls.first(where: canOpen) else {
            alert = UserFacingError(code: "unsupported_format")
            return
        }

        cameraSupportTask?.cancel()
        operation?.cancel()
        captureFactsTask?.cancel()
        invalidateDetails()
        cancelAI()
        endGesture()
        generation += 1
        let ticket = generation
        let encoding = preferences.value.rememberOutput ? runEncoding : "adaptive"
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

        startCameraSupportDeadline(openedAt: openedAt ?? services.openClock.now, ticket: ticket)
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
                let preparing = document?.isPreparingCameraSupport == true
                let slow = document?.isOpeningSlowly == true
                document = opened.openingDocument
                document?.isPreparingCameraSupport = preparing
                document?.isOpeningSlowly = slow
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
                        applyInitialPreferences()
                        if restored != nil { armRestoreNotice() }
                        if let replacedName { sourceReplacedNotice = replacedName }
                        refreshExportMetadata()
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
                let error = UserFacingError.service(error)
                restore(previous, error: error)
                operation = nil
            }
        }
    }

    var canCancelOpen: Bool { isRestoring || openRollback != nil }

    /// Silent Q14 rollback. A cancelled native open may finish later; its task
    /// still owns and closes the candidate, never the restored photograph.
    func cancelOpen() {
        guard canCancelOpen else { return }
        let previous = openRollback
        canRestoreAtLaunch = false
        isRestoring = false
        launchTask?.cancel()
        launchTask = nil
        cameraSupportTask?.cancel()
        operation?.cancel()
        operation = nil
        generation += 1
        if let previous { restore(previous, error: nil) }
        else { syncControls() }
    }

    private func startCameraSupportDeadline(openedAt: Duration, ticket: Int) {
        // Arm at launch even before restoreLast identifies the source; a
        // restored photograph adopts this deadline (and until it is identified a
        // slow restore is `isRestoringSlowly`). Once it passes, a RAW is
        // "preparing camera support" and any other format is "opening slowly".
        let clock = services.openClock
        let deadline = openedAt + .milliseconds(1500)
        if clock.now >= deadline, document?.phase == .opening, openRollback != nil {
            publishSlowOpen()
            return
        }
        cameraSupportTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) }
            catch { return }
            guard let self, !Task.isCancelled, generation == ticket else { return }
            if openRollback != nil, document?.phase == .opening { publishSlowOpen() }
            else if isRestoring, document == nil { restoreIsSlow = true }
        }
    }

    /// 1.5 s without a first frame: a RAW is probably waiting for macOS to
    /// provide the camera's support, anything else is just slow. Either way
    /// the user may cancel (the formats that are not yet known stay silent).
    private func publishSlowOpen() {
        if document?.formatLabel == "RAW" { document?.isPreparingCameraSupport = true }
        else if document != nil { document?.isOpeningSlowly = true }
    }

    func closeDocument() {
        if export.isInFlight {
            pendingPhotoSwitch = PhotoSwitchRequest(kind: .close, displayName: document?.name ?? "")
            return
        }
        prepareForPhotoSwitch()
        canRestoreAtLaunch = false
        isRestoring = false
        generation += 1
        cameraSupportTask?.cancel()
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
        thumbnailFrameDidChange()
        syncControls()
    }

    func publishAlert(_ error: UserFacingError?) { alert = error }
    func renameDocument(_ name: String) { document?.name = name }

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
            refreshExportMetadata()
            if !thumbnailTrackers.isEmpty { updateSummaryThumbnail() }
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
    @ObservationIgnored var editedPresentationTrace: PreviewTrace?
    @ObservationIgnored var referencePresentationTrace: PreviewTrace?
    var currentEditedFrame: PreviewFrame? { editedFrame }
    var currentReferenceFrame: PreviewFrame? { referenceFrame }

    var previewEdge: Int {
        #if DEBUG
        if let edge = A3StressRunner.edge { return edge }
        #endif
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
                               submittedJob?.options == effectiveOptions() { failAI(error) }
                        }
                    case .superseded(let isLatest):
                        guard isLatest else { continue }
                        if renderScheduler?.hasPending != true { setRefreshing(false) }
                        restart = true
                    case .sourceReplaced:
                        cancelAI()
                        readyGain = nil
                        gainToken = nil
                        reopenReplacedSource(photo)
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
            PreviewTrace.$current.withValue(job.trace) {
                services.submit(photo, options: job.options, maxEdge: submittedEdge)
            }
        }
    }

    func apply(_ event: EditorPreviewEvent, finishesRefresh: Bool = true) {
        switch event {
        case .reference(let frame):
            cameraSupportTask?.cancel()
            cameraSupportTask = nil
            document?.isPreparingCameraSupport = false
            document?.isOpeningSlowly = false
            document?.phase = .rendering
            referenceFrame = frame.frame
            referencePresentationTrace = frame.trace
            editedPresentationTrace = nil
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
            cameraSupportTask?.cancel()
            cameraSupportTask = nil
            document?.isPreparingCameraSupport = false
            document?.isOpeningSlowly = false
            editedFrame = frame.frame
            editedPresentationTrace = frame.trace
            canvas.previewPixelSize = frame.frame.map { CGSize(width: $0.base.width, height: $0.base.height) }
            frameRevision &+= 1
            hasEditedFrame = true
            document?.pixelSize = frame.pixelSize
            document?.phase = .ready
            if finishesRefresh { setRefreshing(false) }
            document?.previewError = nil
            leaveSourceUnavailable(announce: true)
            canvas.setImageSize(frame.pixelSize, zoom: canvas.zoom)
            editedGainWeight = frame.hasGain ? frame.frame.map { Double(GainWeight.value(headroom: display.currentHeadroom, metadata: $0.metadata)) } ?? frame.gainWeight ?? services.displayState.gainWeight ?? 1 : nil
            display.gainWeight = selectedMode != .original ? editedGainWeight : nil
        case .failed(let error):
            setRefreshing(false)
            document?.previewError = error
            // The work data is gone: nothing can be kept, as when an export finds out.
            if error.code == "session_expired" { handleExportError(error) }
            else { enterSourceUnavailable(error) }
        }
        thumbnailFrameDidChange()
        syncControls()
    }

    /// A newer "original" frame for the same photo (the lens correction
    /// switch changed); everything else on the canvas stays as it is.
    func replaceReference(_ preview: EditorPreview) {
        guard hasReferenceFrame else { return }
        referenceFrame = preview.frame
        referencePresentationTrace = preview.trace
        frameRevision &+= 1
        thumbnailFrameDidChange()
        startScopes(original: true)
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
        cameraSupportTask?.cancel()
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

    private func restore(_ previous: OpenSnapshot, error: UserFacingError?) {
        cameraSupportTask?.cancel()
        cameraSupportTask = nil
        document = previous.document
        photo = previous.photo
        hasReferenceFrame = previous.reference
        hasEditedFrame = previous.edited
        selectedMode = previous.viewMode
        display = previous.display
        editedGainWeight = previous.editedGainWeight
        referencePresentationTrace = nil; editedPresentationTrace = nil
        referenceFrame = previous.referenceFrame
        editedFrame = previous.editedFrame
        thumbnailFrameDidChange()
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
            refreshExportMetadata()
        }
    }
}
