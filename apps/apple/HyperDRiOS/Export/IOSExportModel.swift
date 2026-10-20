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

    static func live() async throws -> ExportStack {
        let configuration = KitConfiguration()
        let sessions = SessionStore(configuration: configuration, formats: InputFormats())
        let engine = try await Engine(configuration: .init(cacheDirectory: configuration.cacheDirectory))
        let render = try RenderEngine()
        let service = RecipeExportService(engine: engine, renderEngine: render, renderer: render, sessions: sessions,
                                          target: ExportTarget(configuration: configuration, sessions: sessions))
        return ExportStack(sessions: sessions, service: service,
                           luts: LUTLibrary(configuration: configuration, sessions: sessions))
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
/// - Frames are not exported on iOS yet; the Photos destination is shown but
///   not available.
@MainActor @Observable final class IOSExportModel {
    enum Page: Hashable { case destination, custom }

    struct Finished {
        let result: RecipeExportResult
        /// The staged copy `fileExporter` and `ShareLink` deliver.
        let file: URL
        var savedToFiles = false
        /// A save to Files that failed (not a cancelled one).
        var deliveryFailed = false
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

    var page = Page.destination
    var destination = ExportDestination.web
    var custom = CustomExportFormat(encoding: .isoGainMapJPEG, gamut: .p3, quality: 90)
    private(set) var phase = Phase.choosing {
        didSet { UIApplication.shared.isIdleTimerDisabled = isRunning }
    }
    /// `fileExporter`'s binding.
    var presentingFileExporter = false

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
    init(makeStack: @escaping @Sendable () async throws -> ExportStack = { try await ExportStack.live() }) {
        let stack = Task { try await makeStack() }
        self.stack = stack
        luts = IOSLUTLibrary { Task { try await stack.value.luts } }
    }

    var choice: ExportChoice {
        page == .destination ? .destination(destination) : .custom(custom)
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// The plan for the current choice, from the editor as it is.
    func plan(_ editor: RecipeEditor) -> ExportPlan? {
        guard let capture = try? editor.exportCapture() else { return nil }
        return ExportPlanner.plan(capture.planRequest(choice))
    }

    /// The long edges offered besides the original size (p7-3c-export §1.3 B).
    static let longEdgePresets = [3840, 2560, 2160, 1080]

    /// The long edges the size picker offers for a photo whose long edge is
    /// `photo`: the original size (nil), the presets smaller than the photo,
    /// and the current limit when it is none of those (typed, or the memory
    /// budget's).
    static func longEdgeChoices(photo: Int?, current: Int?) -> [Int?] {
        var edges = longEdgePresets.filter { edge in photo.map { edge < $0 } ?? true }
        if let current, !edges.contains(current) { edges.append(current) }
        return [nil] + edges.sorted(by: >)
    }

    /// The photo's own long edge, before any limit.
    func photoLongEdge(_ editor: RecipeEditor) -> Int? {
        guard let capture = try? editor.exportCapture() else { return nil }
        return capture.planRequest(choice).source.pixelSize.longEdge
    }

    /// A typed long edge: a positive number below the photo's; anything else
    /// keeps the original size.
    func setLongEdge(_ edge: Int?, photo: Int?) {
        guard let edge, edge > 0, photo.map({ edge < $0 }) ?? true else {
            custom.longEdge = nil
            return
        }
        custom.longEdge = edge
    }

    /// "Change to long edge N px" when memory blocks the export: the custom
    /// page with the choice's settings and the largest long edge the budget
    /// admits.
    func useLongEdge(_ edge: Int, from plan: ExportPlan) {
        if page == .destination { useCustomFormat(from: plan) }
        custom.longEdge = edge
    }

    /// The ceiling the planner's own notice names when it brings the edit's
    /// highlights down (`dest.ceiling` for a destination, `export.rangeClamped`
    /// for a custom format): the one notice with a stop count.
    static func ceiling(in plan: ExportPlan) -> Double? {
        for notice in plan.notices {
            if case .ceiling(let stops, _) = notice { return stops }
        }
        return nil
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

    /// Whether the current choice can start: a settled photo, a destination
    /// that exists on iOS now, and a plan without blockers. The session may
    /// still be hashing; the run waits for it.
    func canStart(_ plan: ExportPlan?, _ editor: RecipeEditor) -> Bool {
        guard isSettled(editor), luts.missingLook(editor) == nil, let plan, plan.isExecutable else { return false }
        return !(page == .destination && destination == .photos)
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
        normalizeGamut()
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
        let request = capture.planRequest(choice)
        let stack = exportStack()
        run += 1
        let run = self.run
        phase = .running(RecipeExportProgress(stage: .preparing))
        waitingForSource = true
        task = Task { [weak self] in
            do {
                let opened = try await opening.task.value
                let stack = try await stack.value
                try Task.checkCancellation()
                self?.sourceReady(run: run)
                // The look's LUT goes from the library into the photo's
                // session, where the service reads it.
                if let look = capture.recipe.activeLook {
                    do { _ = try await stack.luts.apply(try IOSLUTLibrary.libraryID(look.contentHash), to: opened.session) }
                    catch where !Self.isCancellation(error) { throw RecipeExportError.missingLUT }
                }
                let result = try await stack.service.export(
                    session: opened.session, snapshot: capture.snapshot(revision: opened.revision), request: request,
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

    private func sourceReady(run: Int) {
        if run == self.run { waitingForSource = false }
    }

    private func progressed(_ progress: RecipeExportProgress, run: Int) {
        guard run == self.run, case .running = phase else { return }
        phase = .running(progress)
    }

    private func finished(_ finished: Finished, run: Int) {
        guard run == self.run else { return }
        task = nil
        endBackgroundTask()
        phase = .finished(finished)
        // The web destination is "Save to Files…": the save sheet follows.
        if finished.result.resolved.selection == .destination(.web) { presentingFileExporter = true }
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
        if let memory { failure = Failure(key: failure.key, detail: memory.summary, memory: Self.memoryLine(memory)) }
        phase = .failed(failure)
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

    /// The plan's own estimate, when its memory blocks the export.
    static func memoryEstimate(_ plan: ExportPlan) -> String? {
        guard plan.blockers.contains(where: { $0.code == "export_memory_exceeded" }) else { return nil }
        let peak = mebibytes(plan.memory.estimate.peak)
        guard let available = plan.memory.availableBytes else {
            return String(localized: "ios.export.memory.estimateUnknown \(peak)")
        }
        return String(localized: "ios.export.memory.estimate \(peak) \(mebibytes(available))")
    }

    /// The largest long edge the memory budget admits, when memory is what
    /// blocks the export and a smaller size would fit.
    static func admissibleLongEdge(_ plan: ExportPlan) -> Int? {
        guard plan.blockers.contains(where: { $0.code == "export_memory_exceeded" }) else { return nil }
        return plan.memory.maxAdmissibleLongEdge
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
            case .memoryExceeded: return Failure(key: "ios.export.error.memory", detail: nil)
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
