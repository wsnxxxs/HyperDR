import Foundation
import HyperDREngine
import HyperDRKit
import UniformTypeIdentifiers

// App-internal boundary. A2 supplies live services without changing Views.
@MainActor protocol EditorServices: AnyObject {
    var engineStatus: EngineStatus { get }
    var openClock: any EditorOpenClock { get }
    var displayState: DisplayState { get }
    var openableContentTypes: [UTType] { get }
    /// Where app preferences (the frame settings) live. Live services use the
    /// user's defaults; fakes use a throwaway suite so tests never touch them.
    var preferences: UserDefaults { get }
    /// The current engine status, then every change.
    func engineUpdates() -> AsyncStream<EngineStatus>
    /// The editor scene started: begin service housekeeping once.
    func start() async
    func canOpen(_ url: URL) -> Bool
    func placeholder(for url: URL) -> EditorPhoto
    func open(_ url: URL) async throws -> EditorPhoto
    /// The photo remembered from the last launch, opened and attached.
    func restoreLast() async -> RestoreResult
    /// One open: the reference frame, then the first edit frame rendered
    /// with `EditBaseline.initial(encoding:preview:)` of that reference. The
    /// stream ends after the edit frame or a failure.
    func previews(for photo: EditorPhoto, encoding: String,
                  maxEdge: Int) -> AsyncStream<EditorPreviewEvent>
    /// The results of `submit` for an opened photo, for as long as it is open.
    func refreshes(for photo: EditorPhoto) -> AsyncStream<EditorRefreshEvent>
    /// Queues a refresh with the newest values and returns immediately; the
    /// services keep at most the newest request (latest wins).
    func submit(_ photo: EditorPhoto, options: EditOptions, maxEdge: Int)
    /// The models this engine build offers.
    func renderDetail(_ photo: EditorPhoto, options: EditOptions, region: PreviewRegion,
                      original: Bool) async throws -> EditorPreview?
    func modelTable() -> ModelTable
    /// The identity a gain for these options would have now.
    func modelGainToken(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainToken
    /// Computes (or finds cached) the AI gain for these options.
    func computeModelGain(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainOutcome
    func displayUpdates() -> AsyncStream<DisplayState>
    /// The photograph's Exif for a frame caption; empty when it has none.
    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts
    func close(_ photo: EditorPhoto) async
    func startExport(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?, destination: URL?) async throws -> EditorExportTicket
    func exportEvents(_ job: String) -> AsyncStream<EditorExportEvent>
    func cancelAllExports() async
    func hasExportActivity() async -> Bool
    func commandLine(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?) async throws -> [String]
    func exportKey(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?) async throws -> String
    func exports(for photo: EditorPhoto) async throws -> [ExportHistoryItem]
    func exportTimingHistory() async -> [ExportTimingSample]
    func suggestedFileName(_ photo: EditorPhoto, options: EditOptions) async throws -> String
    func validateDestination(_ url: URL, expectedExtension: String) async throws
    func saveExport(_ photo: EditorPhoto, export: String, destination: URL?) async throws -> SavedLocation
    func exportFolder() async -> ExportFolder
    func setExportFolder(_ url: URL) async throws -> ExportFolder
    func encodingCapabilities() async throws -> EditorCapabilities
    func aboutInformation() async -> AboutInformation
    func diagnostics() async -> String
    func lutEntries() async -> [LUTItem]
    func importLUT(_ url: URL) async throws -> LUTItem
    func applyLUT(_ id: String, to photo: EditorPhoto) async throws -> LUTItem
    func updateLUT(_ id: String, input: LUTColorSpace, output: LUTColorSpace) async throws -> LUTItem
    func removeLUT(_ id: String) async throws
}

/// Outcome of restoring the last photo on launch (A2).
enum RestoreResult {
    /// No remembered photo, or it expired: the empty state, silently.
    case none
    case restored(EditorPhoto)
    /// A remembered photo that can no longer be opened (`source_missing`).
    case unavailable(UserFacingError)
}

/// One opened photo. `handle` makes every open distinct, so closing an
/// earlier open of the same file never closes a later one.
struct EditorPhoto: Hashable {
    let url: URL
    let name: String
    let formatLabel: String
    let byteCount: Int64
    var handle = UUID()

    var openingDocument: DocumentState {
        DocumentState(name: name, formatLabel: formatLabel, byteCount: byteCount,
                      pixelSize: nil, phase: .opening, isRefreshing: false,
                      source: nil, previewError: nil)
    }
}

struct EditorPreview {
    /// The source photo's oriented, cropped size, not the preview's.
    let pixelSize: PixelSize
    let source: SourceSummary
    let hasGain: Bool
    /// The weight the engine rendered the gain with; A3 tracks the screen.
    var gainWeight: Double?
    /// The engine frame to draw; the fakes have none.
    var frame: PreviewFrame?
    /// An HDR source's own control values (its identity rendering).
    var unadjusted: [String: Double]? = nil
    /// The photo has the capture parameters the EXIF model needs.
    var hasCaptureMetadata = false
    var trace: PreviewTrace? = nil
}

enum EditorPreviewEvent {
    case reference(EditorPreview), edited(EditorPreview), failed(UserFacingError)
}

enum EditorRefreshEvent {
    /// A refreshed edit frame. `isLatest` is false for a frame of an older
    /// request finishing while a newer one is queued: it is shown, but the
    /// document stays refreshing.
    case edited(EditorPreview, isLatest: Bool)
    /// The newest request failed; the shown frame stays.
    case failed(UserFacingError)
    /// An obsolete request must not end the latest request’s busy state.
    case superseded(isLatest: Bool)
    /// The source file changed on disk: the photo has to be opened anew.
    case sourceReplaced
}

extension UserDefaults {
    /// A defaults suite of its own, for fakes and tests. Remove it with
    /// `removePersistentDomain(forName:)` when done.
    static func ephemeral() -> (defaults: UserDefaults, name: String) {
        let name = "com.hyperdr.ephemeral.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

@MainActor final class FakeEditorServices: EditorServices {
    var engineStatus: EngineStatus = .ready(version: "fixture-v1")
    var displayState = DisplayState(screenName: "", currentHeadroom: 2.4,
                                    potentialHeadroom: 10.15, gainWeight: nil)
    var openDelay: Duration
    var previewDelay: Duration
    var openFailures: [URL: UserFacingError] = [:]
    var previewFailure: UserFacingError?
    var restoreResult = RestoreResult.none
    var preview = EditorPreview(pixelSize: PixelSize(width: 6000, height: 4000),
        source: SourceSummary(domain: .sceneReferred, colorName: "Display P3", degradationReasons: []),
        hasGain: true)
    let preferences: UserDefaults
    private let preferencesName: String
    private(set) var renderedPurposes: [Bool] = [] // true = reference, false = edit
    private(set) var receivedOptions: [EditOptions] = []
    private(set) var receivedEdges: [Int] = []
    var models = ModelTable(runtimeReady: true, defaultID: "research-cnn-v1", models: [
        ModelChoice(id: "research-cnn-v1", name: "CNN", nameKey: "model.research-cnn-v1",
                    summaryKey: "model.research-cnn-v1.summary", isEnabled: true, requiresCapture: false),
        ModelChoice(id: "research-exif-v1", name: "EXIF", nameKey: "model.research-exif-v1",
                    summaryKey: "model.research-exif-v1.summary", isEnabled: true, requiresCapture: true),
    ])
    var diagnosticHandler: ((EditorPhoto, EditOptions, ExportFrame?) async throws -> [String])?
    fileprivate(set) var diagnosticCalls = 0
    var exportStartHandler: (() async throws -> Void)?
    var exportCancelHandler: (() async -> Void)?
    var exportSaveHandler: ((String, URL?) async throws -> SavedLocation)?
    var metadataHandler: (() async throws -> Void)?
    var historyByURL: [URL: [ExportHistoryItem]] = [:]
    var timings: [ExportTimingSample] = []
    var folder = ExportFolder()
    var capabilityFixture: EditorCapabilities?
    var library: [LUTItem] = []
    var lutEntriesHandler: (() async -> [LUTItem])?
    var removeLUTHandler: ((String) async throws -> Void)?
    var importedLUT: LUTItem?
    var updateLUTHandler: ((String, LUTColorSpace, LUTColorSpace) async throws -> LUTItem)?
    private(set) var exportCalls: [(photo: EditorPhoto, options: EditOptions, frame: ExportFrame?, destination: URL?)] = []
    private(set) var saveCalls: [(String, URL?)] = []
    private(set) var exportCancelCount = 0
    private(set) var activeExport = false
    private var exportSinks: [String: AsyncStream<EditorExportEvent>.Continuation] = [:]
    var detailHandler: ((PreviewRegion, Bool) async throws -> EditorPreview?)?
    private(set) var detailRequests: [(region: PreviewRegion, original: Bool)] = []
    var autoCompletesRefreshes = true
    var gainGate: (() async throws -> Void)?
    var gainDelay: Duration = .milliseconds(20)
    var gainFailure: UserFacingError?
    var missingCaptureFields: [String] = []
    private(set) var gainComputations: [EditOptions] = []
    private(set) var startCount = 0
    private(set) var closed: [EditorPhoto] = []
    private var displays: [UUID: AsyncStream<DisplayState>.Continuation] = [:]
    private var refreshObservers: [UUID: (photo: EditorPhoto, continuation: AsyncStream<EditorRefreshEvent>.Continuation)] = [:]
    private var latestSubmit = 0

    init(openDelay: Duration = .milliseconds(30), previewDelay: Duration = .milliseconds(30)) {
        self.openDelay = openDelay
        self.previewDelay = previewDelay
        (preferences, preferencesName) = UserDefaults.ephemeral()
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: preferencesName)
    }

    var openableContentTypes: [UTType] {
        [.jpeg, .png, .tiff, .heic, .heif] +
            ["public.avif", "public.camera-raw-image"].compactMap { UTType($0) }
    }

    func engineUpdates() -> AsyncStream<EngineStatus> {
        let status = engineStatus
        return AsyncStream { $0.yield(status) }
    }

    func start() async { startCount += 1 }

    func canOpen(_ url: URL) -> Bool {
        url.isFileURL && Self.formatLabel(for: url) != nil
    }

    func placeholder(for url: URL) -> EditorPhoto {
        EditorPhoto(url: url, name: url.lastPathComponent,
                    formatLabel: Self.formatLabel(for: url) ?? "", byteCount: 0)
    }

    nonisolated static func formatLabel(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "JPEG"
        case "png": "PNG"
        case "tif", "tiff": "TIFF"
        case "heic", "heif", "hif": "HEIC"
        case "avif": "AVIF"
        case "arw", "dng", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw", "raw": "RAW"
        default: nil
        }
    }

    func open(_ url: URL) async throws -> EditorPhoto {
        try await Task.sleep(for: openDelay)
        if let error = openFailures[url] { throw error }
        guard let label = Self.formatLabel(for: url), canOpen(url) else {
            throw UserFacingError(code: "unsupported_format")
        }
        return EditorPhoto(url: url, name: url.lastPathComponent, formatLabel: label,
                           byteCount: 24_000_000)
    }

    func restoreLast() async -> RestoreResult { restoreResult }

    func previews(for photo: EditorPhoto, encoding: String,
                  maxEdge: Int) -> AsyncStream<EditorPreviewEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await Task.sleep(for: previewDelay)
                    try Task.checkCancellation()
                    if let error = previewFailure {
                        continuation.yield(.failed(error)); continuation.finish(); return
                    }
                    renderedPurposes.append(true)
                    let reference = preview
                    continuation.yield(.reference(reference))
                    try await Task.sleep(for: previewDelay)
                    try Task.checkCancellation()
                    if let error = previewFailure { continuation.yield(.failed(error)) }
                    else {
                        renderedPurposes.append(false)
                        receivedOptions.append(EditBaseline.initial(encoding: encoding, preview: reference))
                        continuation.yield(.edited(preview))
                    }
                } catch { /* Stream termination owns cancellation. */ }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func refreshes(for photo: EditorPhoto) -> AsyncStream<EditorRefreshEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            refreshObservers[id] = (photo, continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.refreshObservers.removeValue(forKey: id) }
            }
        }
    }

    /// Renders after `previewDelay`; a newer submit wins, as in PreviewService.
    func submit(_ photo: EditorPhoto, options: EditOptions, maxEdge: Int) {
        latestSubmit += 1
        let ticket = latestSubmit
        receivedOptions.append(options)
        receivedEdges.append(maxEdge)
        guard autoCompletesRefreshes else { return }
        Task { @MainActor [weak self] in
            guard let delay = self?.previewDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, ticket == latestSubmit else { return }
            renderedPurposes.append(false)
            let event: EditorRefreshEvent = previewFailure.map { .failed($0) }
                ?? .edited(preview, isLatest: true)
            sendRefresh(event, for: photo)
        }
    }

    func sendRefresh(_ event: EditorRefreshEvent, for photo: EditorPhoto) {
        for observer in refreshObservers.values where observer.photo == photo {
            observer.continuation.yield(event)
        }
    }

    func displayUpdates() -> AsyncStream<DisplayState> {
        let id = UUID()
        return AsyncStream { continuation in
            displays[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.displays.removeValue(forKey: id) }
            }
        }
    }

    func sendDisplay(_ state: DisplayState) {
        displayState = state
        for continuation in displays.values { continuation.yield(state) }
    }

    var facts = CaptureFacts(make: "SONY", model: "ILCE-7RM5", lens: "FE 24-70mm F2.8 GM II",
        focalLength: 35, fNumber: 8, exposureTime: 1.0 / 250, iso: 100, dateTimeOriginal: "2026:09:21 17:42:10")

    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts { facts }

    func close(_ photo: EditorPhoto) async { closed.append(photo) }

    func renderDetail(_ photo: EditorPhoto, options: EditOptions, region: PreviewRegion,
                      original: Bool) async throws -> EditorPreview? {
        detailRequests.append((region, original))
        return try await detailHandler?(region, original)
    }

    func modelTable() -> ModelTable { models }

    /// The fake's stand-in for the Kit's `ModelGainInputs`: model, input
    /// colour and the sRGB clamp.
    static func gainInputs(_ options: EditOptions) -> [String: JSONValue] {
        ["modelId": options["modelId"] ?? .null, "colorGamut": options["colorGamut"] ?? .null,
         "clampSrgb": options["clampSrgb"] ?? .null]
    }

    func modelGainToken(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainToken {
        ModelGainToken(value: Self.gainInputs(options))
    }

    func computeModelGain(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainOutcome {
        gainComputations.append(options)
        if let gainGate { try await gainGate() }
        else { try await Task.sleep(for: gainDelay) }
        if let gainFailure { throw gainFailure }
        return ModelGainOutcome(token: ModelGainToken(value: Self.gainInputs(options)),
                                missingCaptureFields: missingCaptureFields)
    }
}

extension EditorServices {
    /// Fakes without native pixels have no detail image.
    func renderDetail(_ photo: EditorPhoto, options: EditOptions, region: PreviewRegion,
                      original: Bool) async throws -> EditorPreview? { nil }
}

enum EditorDetailError: Error { case sourceReplaced }


extension FakeEditorServices {
    func startExport(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?, destination: URL?) async throws -> EditorExportTicket {
        exportCalls.append((photo, options, frame, destination)); activeExport = true
        do { try await exportStartHandler?(); try Task.checkCancellation() }
        catch { activeExport = false; throw error }
        return EditorExportTicket(job: "fake-job", argv: ["HyperDR", "--output", destination?.path ?? "folder"])
    }
    func exportEvents(_ job: String) -> AsyncStream<EditorExportEvent> {
        AsyncStream { exportSinks[job] = $0 }
    }
    func sendExport(_ event: EditorExportEvent) {
        for sink in exportSinks.values { sink.yield(event) }
        if case .finished = event { activeExport = false; for sink in exportSinks.values { sink.finish() }; exportSinks = [:] }
    }
    var hasExportSubscriber: Bool { !exportSinks.isEmpty }
    func cancelAllExports() async { exportCancelCount += 1; await exportCancelHandler?(); activeExport = false }
    func hasExportActivity() async -> Bool { activeExport }
    func exports(for photo: EditorPhoto) async throws -> [ExportHistoryItem] {
        try await metadataHandler?(); return historyByURL[photo.url] ?? []
    }
    func exportTimingHistory() async -> [ExportTimingSample] { timings }
    func commandLine(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?) async throws -> [String] {
        diagnosticCalls += 1
        if let diagnosticHandler { return try await diagnosticHandler(photo, options, frame) }
        return ["HyperDR", "convert", "photo." + photo.url.pathExtension, "--output", "out", "--report", "out/report.json"]
    }
    func exportKey(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?) async throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(options.values), as: UTF8.self) + String(describing: frame)
    }
    func saveExport(_ photo: EditorPhoto, export: String, destination: URL?) async throws -> SavedLocation {
        saveCalls.append((export, destination))
        if let exportSaveHandler { return try await exportSaveHandler(export, destination) }
        return SavedLocation(fileName: destination?.lastPathComponent ?? "saved.heic", folderLabel: folder.label)
    }
    func exportFolder() async -> ExportFolder {
        guard folder.ready else { return folder }
        return capturedFolder(label: folder.label)
    }
    private func capturedFolder(label: String) -> ExportFolder {
        ExportFolder(label: label, ready: true, target: ExportFolderTarget { [weak self] _, export in
            guard let self else { throw UserFacingError(code: "engine_unavailable") }
            saveCalls.append((export, nil))
            if let exportSaveHandler { return try await exportSaveHandler(export, nil) }
            return SavedLocation(fileName: "saved.heic", folderLabel: label)
        })
    }
    func setExportFolder(_ url: URL) async throws -> ExportFolder { folder = capturedFolder(label: url.lastPathComponent); return folder }
    func encodingCapabilities() async throws -> EditorCapabilities {
        capabilityFixture ?? EditorCapabilities(encodings: Dictionary(uniqueKeysWithValues: Preferences.encodings.map { ($0, .init(available: true, reason: "")) }), main8: true, main10: true)
    }
    func lutEntries() async -> [LUTItem] { if let lutEntriesHandler { return await lutEntriesHandler() }; return library }
    func importLUT(_ url: URL) async throws -> LUTItem {
        guard let importedLUT else { throw UserFacingError(code: "lut_invalid") }
        if !library.contains(where: { $0.id == importedLUT.id }) { library.append(importedLUT) }
        return importedLUT
    }
    func applyLUT(_ id: String, to photo: EditorPhoto) async throws -> LUTItem {
        guard let item = library.first(where: { $0.id == id }) else { throw UserFacingError(code: "lut_invalid") }; return item
    }
    func updateLUT(_ id: String, input: LUTColorSpace, output: LUTColorSpace) async throws -> LUTItem {
        if let updateLUTHandler { return try await updateLUTHandler(id, input, output) }
        guard let i = library.firstIndex(where: { $0.id == id }) else { throw UserFacingError(code: "lut_invalid") }
        library[i].input = input; library[i].output = output; return library[i]
    }
    func removeLUT(_ id: String) async throws {
        if let removeLUTHandler { try await removeLUTHandler(id); return }
        library.removeAll { $0.id == id }
    }
}
