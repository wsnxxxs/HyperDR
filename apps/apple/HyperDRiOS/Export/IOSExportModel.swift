import Foundation
import HyperDREngine
import HyperDRKit
import HyperDRRender
import Observation
import UIKit

/// Kit's export service and the session store it exports from. Export has
/// its own `RenderEngine`, apart from the editor's, so its caches go with it;
/// the AI prediction is the service's default.
nonisolated struct ExportStack: Sendable {
    let sessions: SessionStore
    let service: any RecipeExportServicing
    /// The LUT library, on the same session store: an export applies the
    /// look's LUT from it into the photo's session.
    let luts: LUTLibrary
    /// This device's encoder facts, which the plan checks formats against (K6).
    var capabilities = ExportEncodingCapabilities()

    static func live() async throws -> ExportStack {
        let configuration = KitConfiguration()
        let sessions = SessionStore(configuration: configuration, formats: InputFormats())
        let engine = try await Engine(configuration: .init(cacheDirectory: configuration.cacheDirectory))
        let render = try RenderEngine()
        let service = RecipeExportService(engine: engine, renderEngine: render, renderer: render, sessions: sessions,
                                          target: ExportTarget(configuration: configuration, sessions: sessions))
        return ExportStack(sessions: sessions, service: service,
                           luts: LUTLibrary(configuration: configuration, sessions: sessions),
                           capabilities: ExportEncodingCapabilities(try await engine.capabilities()))
    }
}

/// The iOS export flow (P7-3b-U, p7-adjustments §4.4): the choice of a
/// destination or a custom format, the run with its stages, and the verified
/// version handed to Files or the share sheet.
///
/// - The photo's Kit session opens (and hashes the file) alongside the
///   editor's decoding, as soon as the copy exists; its source revision is
///   captured then. Export does not wait for it to be enabled: a run waits for
///   that same task while it is preparing.
/// - Export is closed while a photo is loading, and a photo cannot start
///   loading while an export runs: the host drops the previous photo's copy
///   and session as soon as the next one opens (R26-002).
/// - The app stays in front while exporting (no background GPU on a free
///   team): the screen does not lock; leaving HyperDR cancels the run, except
///   for publishing and delivering, which finish in a background task.
/// - Cancelling the run cancels the service's task. Cancelling the system
///   save sheet only cancels that delivery: the verified version stays, and
///   can be saved or shared again.
/// - The presentation frame the user chose goes with every export: Kit lays
///   it out around the photo at the size the choice writes, and Render
///   composites it (`FrameExportPlan`). The Photos destination adds the
///   verified file to the library as a new photo; any finished export can
///   be added the same way.
@MainActor @Observable final class IOSExportModel {
    enum Page: String, Hashable, Codable { case destination, custom }

    /// The choice as it is kept between launches.
    private struct SavedChoice: Codable {
        var page: Page
        var destination: ExportDestination
        var custom: CustomExportFormat
    }

    /// What the frame is laid out from: the user's settings and the photo's Exif.
    struct Framing: Equatable {
        var settings: FrameSettings
        var facts: CaptureFacts
    }

    /// One frame plan, for one choice of one photo.
    private struct FrameKey: Equatable {
        let framing: Framing
        let size: PixelSize
        let choice: ExportChoice
    }

    struct Finished {
        let result: RecipeExportResult
        /// The staged copy `fileExporter` and `ShareLink` deliver.
        let file: URL
        var savedToFiles = false
        /// A save to Files that failed (not a cancelled one).
        var deliveryFailed = false
        var photos = PhotosSave.idle
    }

    /// Adding the finished file to the photo library.
    enum PhotosSave: Equatable {
        case idle, saving, saved
        /// An `ios.*` catalogue key: access refused, or the library's error.
        case failed(String)
    }

    struct Failure {
        /// An `ios.*` catalogue key.
        let key: String
        /// Developer-facing detail, shown small.
        let detail: String?
        /// Which memory check failed and its numbers, for reporting.
        var memory: String?
        /// Stopped by leaving the app: "Export again" restarts with the edit.
        var restartable = false
        /// Out of memory: the largest long edge that fits.
        var suggestedLongEdge: Int?
    }

    enum Phase {
        case choosing
        case running(RecipeExportProgress?)
        case finished(Finished)
        case failed(Failure)
    }

    /// A photo's Kit session, opening or open.
    private struct Opening {
        struct Opened: Sendable {
            let session: SessionID
            let revision: RecipeSourceRevision
        }
        let url: URL
        let task: Task<Opened, any Error>
    }

    // The last choice is kept, so the next export starts from it.
    var page = Page.destination { didSet { saveChoice() } }
    var destination = ExportDestination.web { didSet { saveChoice() } }
    var custom = CustomExportFormat(encoding: .isoGainMapJPEG, gamut: .p3, quality: 90) { didSet { saveChoice() } }
    /// Each format tile's last encoding, so going back to a tile restores it.
    @ObservationIgnored private var familyEncodings: [ExportFamily: ExportEncoding] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    static let choiceKey = "HyperDRExportChoice"
    private(set) var phase = Phase.choosing {
        didSet { UIApplication.shared.isIdleTimerDisabled = isRunning }
    }
    /// How far the running export has come, as one ring that fills once:
    /// Kit's overall fraction, never moving back. Nil until the first row.
    private(set) var fraction: Double?
    /// `fileExporter`'s binding.
    var presentingFileExporter = false

    /// The device's encoder facts, once the stack is up.
    private(set) var capabilities = ExportEncodingCapabilities()

    /// The frame exports carry, set by the session.
    var framing = Framing(settings: FrameSettings(), facts: CaptureFacts())
    /// The last frame plan: its caption is drawn into a PNG, once per choice.
    @ObservationIgnored private var frameCache: (key: FrameKey, plan: Result<FrameExportPlan?, any Error>)?

    /// Whether the editor's photo has a session (open or still opening).
    private(set) var hasPhoto = false
    /// The host's photo request being loaded (copied or decoded), from the
    /// moment the host accepts it.
    private(set) var loadingRequest: UUID?
    var loadingPhoto: Bool { loadingRequest != nil }
    /// Why the photo's session could not be opened.
    private(set) var sessionFailure: String?
    @ObservationIgnored private var current: Opening?
    /// The photo the editor is still opening.
    @ObservationIgnored private var pending: Opening?
    @ObservationIgnored private let stack: Task<ExportStack, any Error>
    /// The library's LUTs, installed into the editor.
    let luts: IOSLUTLibrary
    /// The run the app's leaving cancelled.
    @ObservationIgnored private var leftRun: Int?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0
    /// The run is waiting for the session, before the service has it.
    @ObservationIgnored private var waitingForSource = false

    /// The stack is made at once: the LUT library is read at launch.
    /// `defaults` keeps the last choice; nil keeps nothing.
    init(defaults: UserDefaults? = .standard,
         makeStack: @escaping @Sendable () async throws -> ExportStack = { try await ExportStack.live() }) {
        let stack = Task { try await makeStack() }
        self.stack = stack
        self.defaults = defaults
        luts = IOSLUTLibrary { Task { try await stack.value.luts } }
        if let data = defaults?.data(forKey: Self.choiceKey),
           let saved = try? JSONDecoder().decode(SavedChoice.self, from: data) {
            var format = saved.custom
            // A long edge that is not a preset was that photo's (typed, or
            // the memory budget's).
            if let edge = format.longEdge, !ExportLongEdge.presets.contains(edge) { format.longEdge = nil }
            page = saved.page
            destination = saved.destination
            custom = format
            familyEncodings[ExportFamily(format.encoding)] = format.encoding
        }
        Task { [weak self] in
            if let capabilities = try? await stack.value.capabilities { self?.capabilities = capabilities }
        }
    }

    var choice: ExportChoice {
        page == .destination ? .destination(destination) : .custom(custom)
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isChoosing: Bool {
        if case .choosing = phase { return true }
        return false
    }

    /// The plan for the current choice, from the editor as it is, with the
    /// frame's canvas when the frame is on.
    func plan(_ editor: RecipeEditor) -> ExportPlan? {
        guard let capture = try? editor.exportCapture() else { return nil }
        let frame = (try? framePlan(capture, choice: choice).get()) ?? nil
        return ExportPlanner.plan(capture.planRequest(choice, frame: Self.facts(frame), capabilities: capabilities))
    }

    /// The frame for this choice of this photo: nil while the frame is off;
    /// a failure when the engine refuses the style for the photo.
    private func framePlan(_ capture: EditorExportCapture, choice: ExportChoice) -> Result<FrameExportPlan?, any Error> {
        guard framing.settings.isEnabled else { return .success(nil) }
        let size = capture.source.pixelSize
        let key = FrameKey(framing: framing, size: size, choice: choice)
        if let frameCache, frameCache.key == key { return frameCache.plan }
        let plan = Result { try FrameExportPlan.make(settings: framing.settings, facts: framing.facts, photoSize: size,
                                                     choice: choice) }
        frameCache = (key, plan)
        return plan
    }

    private static func facts(_ frame: FrameExportPlan?) -> ExportFrameFacts {
        ExportFrameFacts(canvas: frame.map { ExportPixelSize(width: $0.layout.width, height: $0.layout.height) })
    }

    /// The frame is on and the engine refuses its style for this photo.
    func frameMisfits(_ editor: RecipeEditor) -> Bool {
        guard framing.settings.isEnabled, let capture = try? editor.exportCapture() else { return false }
        if case .failure = framePlan(capture, choice: choice) { return true }
        return false
    }

    /// The written size: the frame's canvas, else the photo after the
    /// choice's size limit.
    func outputSize(_ plan: ExportPlan, _ editor: RecipeEditor) -> (width: Int, height: Int) {
        if let capture = try? editor.exportCapture(), case .success(let frame?) = framePlan(capture, choice: choice) {
            return (frame.layout.width, frame.layout.height)
        }
        return (plan.size.width, plan.size.height)
    }

    /// Why a destination cannot be chosen: only the Photos destination
    /// before its saving is verified (the plan's `photosNotAvailable`).
    func unavailableReason(_ destination: ExportDestination, _ editor: RecipeEditor) -> ExportBlockReason? {
        guard let capture = try? editor.exportCapture() else { return nil }
        return ExportPlanner.plan(capture.planRequest(.destination(destination), capabilities: capabilities))
            .blockers.first { $0.destinationShortPhrase != nil }
    }

    /// Why an encoding cannot be written here (no HEVC encoder, HDR off):
    /// the same answer the plan gives (K6).
    func unavailableReason(_ encoding: ExportEncoding, _ editor: RecipeEditor) -> ExportBlockReason? {
        guard let capture = try? editor.exportCapture() else { return nil }
        let request = capture.planRequest(.custom(custom), capabilities: capabilities)
        return ExportPlanner.availability(of: encoding, source: request.source, capabilities: capabilities, edit: request.edit)
    }

    /// The photo's own long edge, before any limit.
    func photoLongEdge(_ editor: RecipeEditor) -> Int? {
        guard let capture = try? editor.exportCapture() else { return nil }
        return capture.planRequest(choice).source.pixelSize.longEdge
    }

    /// A picked or typed long edge (`ExportLongEdge.normalized`).
    func setLongEdge(_ edge: Int?, photo: Int?) {
        custom.longEdge = ExportLongEdge.normalized(edge, photo: photo)
    }

    /// "Change to long edge N px" when memory blocks the export: the custom
    /// page with the choice's settings and the largest long edge the budget
    /// admits.
    func useLongEdge(_ edge: Int, from plan: ExportPlan?) {
        if page == .destination { useCustomFormat(from: plan) }
        custom.longEdge = edge
    }

    /// The ceiling the export actually applied, from Render's report: the
    /// edit's resolved range before and after it.
    static func appliedCeiling(_ result: RecipeExportResult) -> Double? {
        result.ceilingApplied?.written
    }

    /// Whether an export can be opened or started: a photo, and no other
    /// photo on its way in to replace it.
    func isSettled(_ editor: RecipeEditor) -> Bool {
        hasPhoto && !loadingPhoto && pending == nil && !editor.isOpening
    }

    /// Whether a new photo may start loading: not while an export runs.
    var canOpenPhoto: Bool { !isRunning }

    /// The host accepted a request to open another photo; export is closed
    /// until that request ends (a newer request takes over).
    func photoRequested(_ id: UUID) {
        loadingRequest = id
    }

    /// The host's request ended: opened, failed, cancelled or refused.
    func photoRequestEnded(_ id: UUID) {
        if loadingRequest == id { loadingRequest = nil }
    }

    /// Whether the current choice can start: a settled photo and a plan
    /// without blockers (which include a destination not open yet). The session may
    /// still be hashing; the run waits for it.
    func canStart(_ plan: ExportPlan?, _ editor: RecipeEditor) -> Bool {
        isSettled(editor) && luts.missingLook(editor) == nil && !frameMisfits(editor) && plan?.isExecutable == true
    }

    /// "Custom format…": the destination's encoding, gamut and quality carried over.
    func useCustomFormat(from plan: ExportPlan?) {
        if let plan { custom = plan.customCarryingSettings }
        normalizeGamut()
        page = .custom
    }

    /// A custom encoding; an SDR one offers sRGB and Display P3 only (F2).
    func select(_ encoding: ExportEncoding) {
        custom.encoding = encoding
        familyEncodings[ExportFamily(encoding)] = encoding
        normalizeGamut()
    }

    /// The format the settings rows show: the custom one, or what the
    /// destination writes.
    func shownFormat(_ plan: ExportPlan?) -> CustomExportFormat {
        page == .destination ? plan?.customCarryingSettings ?? custom : custom
    }

    /// A format tile: its last encoding, else its first one this photo can
    /// be written in. The custom size and quality stay.
    func select(_ family: ExportFamily, _ editor: RecipeEditor) {
        let candidates = (familyEncodings[family].map { [$0] } ?? []) + family.encodings
        page = .custom
        select(candidates.first { unavailableReason($0, editor) == nil } ?? candidates[0])
    }

    /// A settings row changed. On a destination the row starts a custom
    /// format from the destination's settings: a destination is a starting point.
    func edit(from plan: ExportPlan?, _ change: (inout CustomExportFormat) -> Void) {
        if page == .destination { useCustomFormat(from: plan) }
        var format = custom
        change(&format)
        custom = format
        select(format.encoding)
    }

    private func saveChoice() {
        guard let defaults, let data = try? JSONEncoder().encode(SavedChoice(page: page, destination: destination, custom: custom))
        else { return }
        defaults.set(data, forKey: Self.choiceKey)
    }

    private func normalizeGamut() {
        if custom.encoding.isSDR, custom.gamut == .rec2020 { custom.gamut = .p3 }
    }

    // MARK: - The photo's session

    /// The editor starts opening `url`: its session opens now, in parallel.
    /// A photo still pending from before is dropped.
    func photoOpening(_ url: URL) {
        if let pending { discard(pending) }
        let stack = exportStack()
        pending = Opening(url: url, task: Task {
            let photo = try await stack.value.sessions.open(url)
            return Opening.Opened(session: photo.id, revision: try RecipeSourceRevision(session: photo))
        })
    }

    /// The editor opened `url`: its session replaces the previous photo's.
    func photoOpened(_ url: URL) {
        guard let opening = pending, opening.url == url else { return }
        pending = nil
        if let current { discard(current) }
        current = opening
        hasPhoto = true
        sessionFailure = nil
        Task { [weak self] in
            do { _ = try await opening.task.value } catch {
                guard let self, self.current?.task == opening.task else { return }
                self.sessionFailure = String(describing: error)
            }
        }
    }

    /// The photo was closed: its session goes, and so does any still opening.
    func photoClosed() {
        if let pending { discard(pending) }
        if let current { discard(current) }
        pending = nil
        current = nil
        hasPhoto = false
        sessionFailure = nil
        frameCache = nil
        phase = .choosing
    }

    /// The editor could not open `url`; the previous photo stays.
    func photoFailed(_ url: URL) {
        guard let opening = pending, opening.url == url else { return }
        pending = nil
        discard(opening)
    }

    /// Stops a session's hashing, or closes it once open.
    private func discard(_ opening: Opening) {
        opening.task.cancel()
        let stack = exportStack()
        Task {
            guard let opened = try? await opening.task.value, let stack = try? await stack.value else { return }
            await stack.sessions.close(opened.session)
        }
    }

    private func exportStack() -> Task<ExportStack, any Error> { stack }

    // MARK: - Running

    /// Freezes the edit now; the run then waits for the photo's session
    /// (the one opened with the photo, never a second hash) while preparing.
    func start(_ editor: RecipeEditor) {
        guard !isRunning, isSettled(editor), luts.missingLook(editor) == nil, let opening = current else { return }
        editor.commitDrag()
        let capture: EditorExportCapture
        do { capture = try editor.exportCapture() } catch {
            phase = .failed(Self.failure(error))
            return
        }
        // The edit and the session must be the same photo's.
        guard capture.source.url.standardizedFileURL == opening.url.standardizedFileURL else {
            phase = .failed(Failure(key: "ios.error.sourceChanged", detail: nil))
            return
        }
        let frame: FrameExportPlan?
        do { frame = try framePlan(capture, choice: choice).get() } catch {
            phase = .failed(Failure(key: "ios.frame.misfit", detail: nil))
            return
        }
        let request = capture.planRequest(choice, frame: Self.facts(frame))
        let stack = exportStack()
        run += 1
        let run = self.run
        phase = .running(RecipeExportProgress(stage: .preparing))
        fraction = nil
        waitingForSource = true
        task = Task { [weak self] in
            do {
                let opened = try await opening.task.value
                let stack = try await stack.value
                try Task.checkCancellation()
                self?.sourceReady(run: run)
                // The look's LUT goes from the library into the photo's
                // session, where the service reads it: any look the recipe
                // names, in effect or not (`lutContentHash`).
                if let look = capture.recipe.look {
                    do { _ = try await stack.luts.apply(try IOSLUTLibrary.libraryID(look.contentHash), to: opened.session) }
                    catch where !Self.isCancellation(error) { throw RecipeExportError.missingLUT }
                }
                let result = try await stack.service.export(
                    session: opened.session,
                    snapshot: RecipeExportSnapshot(recipe: capture.recipe, source: opened.revision, frame: frame?.snapshot),
                    request: request,
                    lut: capture.lut, destination: nil,
                    progress: { progress in Task { @MainActor in self?.progressed(progress, run: run) } })
                let file = try await stack.sessions.stageExportForTransfer(opened.session, export: result.record.id)
                self?.finished(Finished(result: result, file: file), run: run)
            } catch {
                // A memory refusal: which check, with the service's numbers.
                var memory: ExportMemoryDiagnostic?
                if case RecipeExportError.memoryExceeded = error, let stack = try? await stack.value {
                    memory = await stack.service.lastMemoryDiagnostic
                }
                self?.failed(error, run: run, memory: memory)
            }
        }
    }

    /// Cancels the run. While it still waits for the session, the sheet goes
    /// back at once; the hashing goes on for the next run.
    func cancel() {
        task?.cancel()
        guard waitingForSource, isRunning else { return }
        run += 1
        task = nil
        waitingForSource = false
        phase = .choosing
    }

    /// Back to the choice, after a result or a failure.
    func reset() {
        guard !isRunning else { return }
        phase = .choosing
    }

    /// The system save sheet closed. A cancel only cancels the delivery.
    func savedToFiles(_ outcome: Result<URL, any Error>) {
        guard case .finished(var finished) = phase else { return }
        switch outcome {
        case .success:
            finished.savedToFiles = true
            finished.deliveryFailed = false
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            finished.deliveryFailed = true
        }
        phase = .finished(finished)
    }

    /// Adds the finished file to the photo library as a new photo, asking
    /// for add-only access the first time.
    func saveToPhotos() {
        guard case .finished(var finished) = phase, finished.photos != .saving, finished.photos != .saved else { return }
        finished.photos = .saving
        phase = .finished(finished)
        let file = finished.file, run = self.run
        Task { [weak self] in
            let outcome: PhotosSave
            do {
                _ = try await PhotoLibrarySaver().addPhoto(file)
                outcome = .saved
            } catch let error as HyperDRError where error.code == "photos_permission_denied" {
                outcome = .failed("ios.export.photosDenied")
            } catch {
                outcome = .failed("ios.export.photosFailed")
            }
            guard let self, run == self.run, case .finished(var current) = self.phase, current.file == file else { return }
            current.photos = outcome
            self.phase = .finished(current)
        }
    }

    private func sourceReady(run: Int) {
        if run == self.run { waitingForSource = false }
    }

    private func progressed(_ progress: RecipeExportProgress, run: Int) {
        guard run == self.run, case .running = phase else { return }
        phase = .running(progress)
        if let next = progress.fraction { fraction = max(fraction ?? 0, next) }
    }

    private func finished(_ finished: Finished, run: Int) {
        guard run == self.run else { return }
        task = nil
        endBackgroundTask()
        phase = .finished(finished)
        // The web destination is "Save to Files…": the save sheet follows;
        // the Photos destination goes into the library.
        switch finished.result.resolved.selection {
        case .destination(.web): presentingFileExporter = true
        case .destination(.photos): saveToPhotos()
        default: break
        }
    }

    private func failed(_ error: any Error, run: Int, memory: ExportMemoryDiagnostic? = nil) {
        guard run == self.run else { return }
        task = nil
        waitingForSource = false
        endBackgroundTask()
        if Self.isCancellation(error) {
            phase = leftRun == run ? .failed(Self.stopped) : .choosing
            return
        }
        var failure = Self.failure(error)
        if let memory {
            failure = Failure(key: failure.key, detail: memory.summary, memory: Self.memoryLine(memory),
                              suggestedLongEdge: failure.suggestedLongEdge)
        }
        phase = .failed(failure)
    }

    // MARK: - History

    /// The versions HyperDR keeps, across photos, newest first.
    func history() async -> [ExportHistoryEntry] {
        guard let stack = try? await stack.value else { return [] }
        return await stack.sessions.exportHistory()
    }

    /// The small SDR picture written with the version.
    func thumbnail(_ entry: ExportHistoryEntry) async -> UIImage? {
        guard let stack = try? await stack.value,
              let data = await stack.sessions.exportThumbnail(entry.session, export: entry.id) else { return nil }
        return UIImage(data: data)
    }

    /// A copy of the version's file to share or save; the version stays.
    func stage(_ entry: ExportHistoryEntry) async throws -> URL {
        try await stack.value.sessions.stageExportForTransfer(entry.session, export: entry.id)
    }

    func remove(_ entry: ExportHistoryEntry) async throws {
        try await stack.value.sessions.removeExportVersion(entry.session, export: entry.id)
    }

    // MARK: - Memory, in MiB for reporting

    static func mebibytes(_ bytes: Int) -> String { String(Int((Double(bytes) / 1_048_576).rounded())) }

    /// "Process memory: needs 3189 MiB, 2400 MiB available", or the GPU's,
    /// or that the format cannot be written in parts.
    static func memoryLine(_ diagnostic: ExportMemoryDiagnostic) -> String {
        let needed = mebibytes(diagnostic.requiredBytes), available = mebibytes(diagnostic.availableBytes)
        if diagnostic.reason == .nonIncrementalWriter {
            return String(localized: "ios.export.memory.writer \(needed) \(available)")
        }
        switch diagnostic.check {
        case .process: return String(localized: "ios.export.memory.process \(needed) \(available)")
        case .gpu: return String(localized: "ios.export.memory.gpu \(needed) \(available)")
        }
    }

    /// A cancelled run (by the user or by leaving the app), not a failure.
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? HyperDRError)?.code == "cancelled"
    }

    // MARK: - Leaving the app

    static let stopped = Failure(key: "ios.export.stopped", detail: nil, restartable: true)

    /// The app went to the background: publishing and delivering (the file
    /// written and verified) finish in a background task; any other stage is
    /// cancelled, and the sheet says so when the app is back.
    func enteredBackground() {
        guard case .running(let progress) = phase else { return }
        if let stage = progress?.stage, stage == .publishing || stage == .delivering {
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "HyperDR export") { [weak self] in
                self?.endBackgroundTask()
            }
            return
        }
        leftRun = run
        if waitingForSource {
            task?.cancel()
            run += 1
            task = nil
            waitingForSource = false
            phase = .failed(Self.stopped)
        } else {
            task?.cancel()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    static func failure(_ error: any Error) -> Failure {
        switch error {
        case let error as RecipeExportError:
            switch error {
            case .busy: return Failure(key: "ios.export.error.busy", detail: nil)
            case .sourceChanged: return Failure(key: "ios.error.sourceChanged", detail: nil)
            case .missingLUT: return Failure(key: "ios.export.error.missingLUT", detail: nil)
            case .missingModel: return Failure(key: "ios.export.error.missingModel", detail: nil)
            case .memoryExceeded(let reason):
                return Failure(key: "ios.export.error.memory", detail: nil, suggestedLongEdge: reason.suggestedLongEdge)
            case .planBlocked(let codes): return Failure(key: "ios.export.blocked", detail: codes.joined(separator: ", "))
            case .verificationFailed(let reason): return Failure(key: "ios.export.error.verification", detail: reason)
            case .invalidSnapshot, .invalidStripes: return Failure(key: "ios.export.error.other", detail: String(describing: error))
            }
        case EditorRenderingError.missingLUT:
            return Failure(key: "ios.export.error.missingLUT", detail: nil)
        case EditorRenderingError.sourceChanged:
            return Failure(key: "ios.error.sourceChanged", detail: nil)
        case let error as HyperDRError:
            return Failure(key: "ios.export.error.other", detail: "\(error.message) (\(error.code))")
        default:
            return Failure(key: "ios.export.error.other", detail: String(describing: error))
        }
    }
}
