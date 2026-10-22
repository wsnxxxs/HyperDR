import AppKit
import Foundation
import HyperDRDesign
import HyperDRKit
import HyperDRRecipe
import HyperDRRender
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class EditorModel {
    private(set) var engine: EngineStatus
    private(set) var workspace: Workspace
    private(set) var document: DocumentState?
    private(set) var display: DisplayState
    private(set) var alert: UserFacingError?
    let canvas = CanvasModel()
    /// The editing session: the recipe, its undo steps, preview rendering and
    /// AI (p7-2b §2). The inspector binds to it.
    let editor: RecipeEditor
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
    /// Each library LUT on the open photo, for the inspector and the library.
    let lookPreviews = LookPreviews()
    let preferences: PreferencesState
    var exportVersions: [ExportVersion] = []
    var exportSaveStates: [String: ExportSaveState] = [:]
    var pendingPhotoSwitch: PhotoSwitchRequest?
    var suggestedFileName = ""
    @ObservationIgnored var cachedFrameKey: ExportFrameCacheKey?
    @ObservationIgnored var cachedExportFrame: FrameExportPlan?
    var exportSummaryThumbnail: ThumbnailState = .unavailable
    var versionThumbnails: [String: ThumbnailState] = [:]
    @ObservationIgnored var thumbnailTrackers: Set<UUID> = []
    @ObservationIgnored var summaryThumbnailTask: Task<Void, Never>?
    @ObservationIgnored var summaryThumbnailTicket = 0
    @ObservationIgnored var summaryThumbnailLastStart: ContinuousClock.Instant?
    @ObservationIgnored var summaryThumbnailFrame: EditorFrame?
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
    /// What an export of the current edit would freeze, which the history's
    /// versions are matched against; nil while it cannot be captured.
    @ObservationIgnored var currentExportSnapshot: RecipeExportSnapshot?
    /// The AI model identity of the version last restored, and its recipe: an
    /// export of exactly that recipe renders it with the same model again.
    @ObservationIgnored var restoredModel: (recipe: Recipe, identity: String)?
    @ObservationIgnored var exportCapabilities: EditorCapabilities?
    @ObservationIgnored var pendingSwitchStops = false
    @ObservationIgnored var lutLibraryReadSequence = 0
    @ObservationIgnored var lutLibraryAcceptedSequence = 0
    @ObservationIgnored var lutMetadataTask: Task<Void, Never>?
    @ObservationIgnored var lutMetadataWrites: [String: LUTMetadataWrite] = [:]
    /// Library LUTs handed to the renderer, by library id: the reference a
    /// recipe stores for each (its content hash and name).
    private(set) var lutReferences: [String: LUTReference] = [:]
    func setLUTReference(_ reference: LUTReference?, for id: String) { lutReferences[id] = reference }
    @ObservationIgnored var lutInstallTask: Task<Void, Never>?
    /// A restore waiting for its look's LUT from the photo's own copy.
    @ObservationIgnored var restoreTask: Task<Void, Never>?
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

    // MARK: Export request (until P7-3b)
    /// The export's own choices. Not the recipe, and never undone.
    @ObservationIgnored var exportChoices = ExportChoices() {
        didSet {
            if oldValue != exportChoices { editGeneration &+= 1; pendingExportToken = nil }
        }
    }
    /// Changes with the export request and with every recipe change, so a
    /// save panel opened before an edit is not honoured after it.
    @ObservationIgnored var editGeneration = 0
    @ObservationIgnored var pendingExportToken: UUID?
    /// The recipe the model last mirrored.
    @ObservationIgnored private var mirroredRecipe: Recipe?
    /// What the open photo told the model about itself.
    @ObservationIgnored var source = PhotoSource()
    let scopes = ScopeState()
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
    /// The output encoding the next photo opens with; kept for this run.
    @ObservationIgnored var runEncoding = "adaptive"

    // MARK: Viewer state (EditorModel+Viewer.swift)
    private(set) var splitRatio = 0.5
    private(set) var isPeekingOriginal = false
    @ObservationIgnored var scopeTask: Task<Void, Never>?
    @ObservationIgnored var originalScopeTask: Task<Void, Never>?
    /// The recipes the scopes on screen were computed for.
    /// The renders the scopes last measured, and the ones being measured
    /// (R27-002: a prediction or a bypass changes the picture, not the recipe).
    @ObservationIgnored var scopedRequest: EditorRenderRequest?
    @ObservationIgnored var scopedOriginal: EditorRenderRequest?
    @ObservationIgnored var scopingRequest: EditorRenderRequest?
    @ObservationIgnored var scopingOriginal: EditorRenderRequest?

    func setSplitRatioValue(_ value: Double) { if value != splitRatio { splitRatio = value } }
    func setPeeking(_ value: Bool) { if value != isPeekingOriginal { isPeekingOriginal = value } }
    func bumpFrameRevision() { frameRevision &+= 1 }
    func clearPreviewError() { if document?.previewError != nil { document?.previewError = nil } }
    func bumpUndoRevision() { undoRevision &+= 1 }
    @ObservationIgnored private let frameClock: any EditorFrameClock
    @ObservationIgnored private var cameraSupportTask: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var captureFactsTask: Task<Void, Never>?
    @ObservationIgnored private var displayObserver: Task<Void, Never>?
    @ObservationIgnored private var displayPublication: Task<Void, Never>?
    @ObservationIgnored private var editorObserver: Task<Void, Never>?
    @ObservationIgnored private var editorReopen: Task<Void, Never>?
    @ObservationIgnored private var pendingDisplay: DisplayState?
    private var openRollback: OpenSnapshot?
    @ObservationIgnored private var editedGainWeight: Double?

    private(set) var frameRevision: UInt64 = 0
    /// The editor's source whose frames the canvas shows; frames of a photo
    /// still opening (or of one being put back) are not shown.
    @ObservationIgnored private(set) var committedSource: UUID?
    /// "Original": the defaults under the same development (p7-2b §5).
    @ObservationIgnored private(set) var referenceFrame: EditorFrame? {
        didSet {
            referencePair = referenceFrame.map { DisplayPair($0.display) }
        }
    }
    @ObservationIgnored private(set) var editedFrame: EditorFrame? {
        didSet {
            editedPair = editedFrame.map { DisplayPair($0.display) }
        }
    }
    @ObservationIgnored private(set) var referencePair: DisplayPair?
    /// What the canvas draws for the edit.
    @ObservationIgnored private(set) var editedPair: DisplayPair?
    @ObservationIgnored private var engineObserver: Task<Void, Never>?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var canRestoreAtLaunch = true
    @ObservationIgnored private var busyTask: Task<Void, Never>?
    @ObservationIgnored var renderOutstanding = false
    /// The last render failure already reported.
    @ObservationIgnored private var reportedFailure: String?
    /// The editor's detail layers the canvas last drew.
    @ObservationIgnored private var shownLayers: [ObjectIdentifier?] = []
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
        let display: DisplayState
        let editedGainWeight: Double?
        let referenceFrame: EditorFrame?
        let editedFrame: EditorFrame?
        let captureFacts: CaptureFacts
        /// The editor's photo and recipe, to put back if the new photo
        /// opened in the editor but never rendered.
        let source: UUID?
        let recipe: Recipe
    }

    init(services: any EditorServices = FakeEditorServices(), document: DocumentState? = nil,
         alert: UserFacingError? = nil, photo: EditorPhoto? = nil,
         hasReferenceFrame: Bool = false, hasEditedFrame: Bool = false,
         frameClock: (any EditorFrameClock)? = nil, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.now = now
        let frameClock = frameClock ?? ContinuousFrameClock()
        self.frameClock = frameClock
        editor = RecipeEditor(renderer: services.rendering, frameClock: frameClock)
        preferences = PreferencesState(Preferences.load(from: services.preferences))
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 0
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
        editor.onLookSpacesChanged = { [weak self] old, new in
            self?.recordLookSpaces(from: old, to: new)
        }
        editor.attach(undoManager: undoManager)
        editor.undo.actionName = { Self.undoActionName($0) }
        // Every step, undo and redo included, is an edit: an export panel
        // prepared before it is stale at once, not when the mirror catches up.
        editor.undo.didRegister = { [weak self] in
            self?.clearRestoreNotice()
            self?.bumpUndoRevision()
            self?.editGeneration &+= 1
            self?.pendingExportToken = nil
        }
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
        observeEditor()
    }

    deinit {
        summaryThumbnailTask?.cancel(); deferredExportThumbnailTask?.cancel(); versionThumbnailTask?.cancel()
        exportTask?.cancel()
        exportMetadataTask?.cancel()
        lutInstallTask?.cancel()
        restoreTask?.cancel()
        lutMetadataTask?.cancel()
        for write in lutMetadataWrites.values { write.task?.cancel() }
        for task in saveTasks.values { task.cancel() }
        cameraSupportTask?.cancel()
        operation?.cancel()
        busyTask?.cancel()
        scopeTask?.cancel()
        originalScopeTask?.cancel()
        captureFactsTask?.cancel()
        launchTask?.cancel()
        engineObserver?.cancel()
        displayObserver?.cancel()
        displayPublication?.cancel()
        editorObserver?.cancel()
        editorReopen?.cancel()
    }

    var viewMode: ViewMode {
        get { selectedMode }
        set {
            guard isAvailable(newValue) else { return }
            selectedMode = newValue
            canvasGeometryChanged()
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
    /// frames, mode and canvas geometry stay visible until its first frame
    /// arrives. Any open failure restores the complete previous state, or the
    /// empty state.
    func open(_ urls: [URL], afterReplacement replacedName: String? = nil) {
        if export.isInFlight {
            guard let url = urls.first(where: canOpen) else { return }
            pendingPhotoSwitch = PhotoSwitchRequest(kind: .open(url), displayName: url.lastPathComponent)
            return
        }
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
        editorReopen?.cancel()
        invalidateDetails()
        editor.commitDrag()
        generation += 1
        let ticket = generation
        let encoding = preferences.value.rememberOutput ? runEncoding : "adaptive"
        var previous = openRollback ?? OpenSnapshot(document: document, photo: photo,
            reference: hasReferenceFrame, edited: hasEditedFrame, viewMode: selectedMode,
            transform: canvas.transform, display: display, editedGainWeight: editedGainWeight,
            referenceFrame: referenceFrame, editedFrame: editedFrame, captureFacts: captureFacts,
            source: committedSource, recipe: editor.recipe)
        setRefreshing(false)
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
                do { try await editor.open(opened.url) } catch let error as UserFacingError { throw error } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Render's own errors: the file could not be read as a photo.
                    throw UserFacingError(code: "decode_failed", detail: String(describing: error))
                }
                try Task.checkCancellation()
                guard generation == ticket, let source = editor.source else { throw CancellationError() }
                document?.pixelSize = PixelSize(source.pixelSize)
                document?.source = SourceSummary(source)
                try await firstFrame(of: source.id)
                try Task.checkCancellation()
                guard generation == ticket else { throw CancellationError() }
                // Commit the opened photo before publishing ready.
                photo = opened
                photoSerial += 1
                captureFacts = CaptureFacts()
                openRollback = nil
                operation = nil
                beginEditing(encoding: encoding, source: source)
                editorChanged()
                startCaptureFacts(opened)
                applyInitialPreferences()
                if restored != nil { armRestoreNotice() }
                if let replacedName { sourceReplacedNotice = replacedName }
                refreshExportMetadata()
                if let old = previous.photo, old != opened { await services.close(old) }
            } catch {
                if let candidate, candidate != previous.photo { await services.close(candidate) }
                guard generation == ticket, !Task.isCancelled else { return }
                restore(previous, error: UserFacingError.service(error))
                operation = nil
            }
        }
    }

    /// Waits until the editor has rendered `source`, or throws its render failure.
    private func firstFrame(of source: UUID) async throws {
        let editor = self.editor
        for await state in Observations({
            (edited: editor.frame?.request.sourceID, failure: editor.renderFailure, current: editor.source?.id)
        }) {
            try Task.checkCancellation()
            guard state.current == source else { throw CancellationError() }
            if state.edited == source { return }
            if let failure = state.failure { throw UserFacingError(code: "decode_failed", detail: failure) }
        }
        throw CancellationError()
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
        editorReopen?.cancel()
        operation = nil
        setRefreshing(false)
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
        endEditing()
        display.gainWeight = nil
        editedGainWeight = nil
        referenceFrame = nil
        editedFrame = nil
        committedSource = nil
        frameRevision &+= 1
        canvas.setImageSize(nil)
        thumbnailFrameDidChange()
        syncControls()
        let editor = self.editor
        editorReopen = Task { await editor.close() }
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

    /// The newest frames of the committed photo.
    var currentEditedFrame: EditorFrame? { editedFrame }
    var currentReferenceFrame: EditorFrame? { referenceFrame }

    func updateViewport(_ size: CGSize, backingScale: Double) {
        canvas.setViewport(size, backingScale: backingScale)
        #if DEBUG
        if let edge = A3StressRunner.edge {
            editor.canvasPixelSize = HyperDRRender.PixelSize(width: edge, height: edge)
            return
        }
        #endif
        let scale = max(1, backingScale)
        let pixels = HyperDRRender.PixelSize(width: Int((size.width * scale).rounded()),
                                             height: Int((size.height * scale).rounded()))
        if pixels.width > 0, pixels.height > 0 { editor.canvasPixelSize = pixels }
    }

    func updateRefreshRate(_ framesPerSecond: Int) {
        (frameClock as? ContinuousFrameClock)?.framesPerSecond = framesPerSecond
    }

    /// A render not caught up starts a 300 ms grace period. Fast frames never
    /// publish busy; an already-visible busy indicator stays until a frame.
    func requestBusy() {
        guard !renderOutstanding else { return }
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

    // MARK: Editor

    private func observeEditor() {
        let editor = self.editor
        editorObserver = Task { [weak self] in
            for await _ in Observations({
                // Everything the model mirrors; `editorChanged` reads the values again.
                (editor.frame?.request, editor.originalFrame?.request, editor.renderFailure,
                 editor.recipe, editor.editingParameter, editor.aiStatus, editor.source?.id,
                 editor.sourceChanged, editor.detailFrame?.request, editor.originalDetailFrame?.request)
            }) {
                guard let self, !Task.isCancelled else { return }
                editorChanged()
            }
        }
    }

    /// Mirrors the editor into the document, the canvas and everything that
    /// follows a frame. Frames of a photo still opening are left alone.
    func editorChanged() {
        guard let source = editor.source, source.id == committedSource, photo != nil else { return }
        let recipe = editor.recipe
        if recipe != mirroredRecipe {
            mirroredRecipe = recipe
            editGeneration &+= 1
            pendingExportToken = nil
            refreshExportMetadata()
        }
        let layers = [editor.shownDetail?.display.base, editor.shownOriginalDetail?.display.base]
            .map { $0.map { ObjectIdentifier($0) } }
        if layers != shownLayers {
            shownLayers = layers
            frameRevision &+= 1
        }
        var changed = false
        if let frame = editor.originalFrame, frame.request.sourceID == source.id,
           referenceFrame?.request != frame.request {
            referenceFrame = frame
            hasReferenceFrame = true
            changed = true
        }
        if let frame = editor.frame, frame.request.sourceID == source.id,
           editedFrame?.request != frame.request {
            editedFrame = frame
            hasEditedFrame = true
            changed = true
            cameraSupportTask?.cancel()
            cameraSupportTask = nil
            document?.isPreparingCameraSupport = false
            document?.isOpeningSlowly = false
            document?.phase = .ready
            document?.previewError = nil
            reportedFailure = nil
            leaveSourceUnavailable(announce: true)
            editedGainWeight = editedPair.map { Double($0.weight(headroom: display.currentHeadroom)) }
            display.gainWeight = selectedMode != .original ? editedGainWeight : nil
        }
        if changed {
            frameRevision &+= 1
            thumbnailFrameDidChange()
        }
        let caughtUp = editor.frame?.request.recipe == recipe && editor.frame?.request.sourceID == source.id
        if caughtUp { setRefreshing(false) } else if editor.renderFailure == nil { requestBusy() }
        if let failure = editor.renderFailure, failure != reportedFailure {
            reportedFailure = failure
            setRefreshing(false)
            renderFailed(failure)
        }
        if caughtUp, !editor.isDragging { startScopes() }
        syncControls()
    }

    /// A render failed and the shown frame stays. A file that is gone is said
    /// as such (and retried); anything else is a preview error.
    private func renderFailed(_ detail: String) {
        guard let photo else { return }
        if !FileManager.default.fileExists(atPath: photo.url.path) {
            enterSourceUnavailable(UserFacingError(code: "source_missing", detail: detail))
        } else {
            document?.previewError = UserFacingError(code: "decode_failed", detail: detail)
            thumbnailFrameDidChange()
        }
    }

    var hasPreviewFrame: Bool { hasReferenceFrame || hasEditedFrame }

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
        editor.commitDrag()
        operation = nil
        setRefreshing(false)
        invalidateDetails()
        let error = UserFacingError(code: "metal_unavailable", detail: detail)
        if let previous = openRollback {
            restore(previous, error: error)
        } else {
            // An opened document with no drawable frame uses .failed. Opening
            // a replacement instead follows Q14's rollback path above.
            document?.phase = .failed(error)
            committedSource = nil
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
        syncControls()
        reopenInEditor(previous)
        if let photo {
            startCaptureFacts(photo)
            refreshExportMetadata()
        }
    }

    /// The editor may already hold the photo that failed: put the previous
    /// one back with its recipe and its undo steps, or close it.
    private func reopenInEditor(_ previous: OpenSnapshot) {
        guard editor.source?.id != previous.source || previous.source == nil else {
            committedSource = previous.source
            return
        }
        committedSource = nil
        let editor = self.editor
        let ticket = generation
        editorReopen?.cancel()
        editorReopen = Task { [weak self] in
            guard let photo = previous.photo, previous.source != nil else {
                if editor.source != nil { await editor.close() }
                return
            }
            do {
                try await editor.open(photo.url, restoring: previous.recipe)
                guard let self, generation == ticket, self.photo == photo else { return }
                bumpUndoRevision()
                committedSource = editor.source?.id
                editorChanged()
            } catch {
                guard let self, generation == ticket, self.photo == photo else { return }
                enterSourceUnavailable(UserFacingError.service(error))
            }
        }
    }

    /// Commits the photo whose first frame is in (called once per open).
    func commit(source: EditorSource) {
        committedSource = source.id
        mirroredRecipe = nil
    }

    static func undoActionName(_ edit: RecipeEdit) -> String {
        switch edit {
        case .parameter(let id): Adjustments.declaration(id).map { AdjustmentText.undoName($0) } ?? AdjustmentText.undoName(.all)
        case .resetGroup(let group): AdjustmentText.undoName(.group(group))
        case .resetAll: AdjustmentText.undoName(.all)
        }
    }
}

extension PixelSize {
    init(_ size: HyperDRRender.PixelSize) { self.init(width: size.width, height: size.height) }
}

extension SourceSummary {
    /// What the inspector says about the editor's source. Render does not
    /// name the colour space or report the decoder's facts yet.
    init(_ source: EditorSource) {
        let domain: InputDomain = switch source.domain {
        case .sdr: .sdr
        case .hdr: .hdr
        case .dual: .dual
        case .rawEDR: .sceneReferred
        }
        self.init(domain: domain, colorName: "", degradationReasons: [])
    }
}
