import Foundation
import HyperDREngine
import HyperDRKit
import UniformTypeIdentifiers

// App-internal boundary. A2 supplies live services without changing Views.
@MainActor protocol EditorServices: AnyObject {
    var engineStatus: EngineStatus { get }
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
    func modelTable() -> ModelTable
    /// The identity a gain for these options would have now.
    func modelGainToken(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainToken
    /// Computes (or finds cached) the AI gain for these options.
    func computeModelGain(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainOutcome
    func displayUpdates() -> AsyncStream<DisplayState>
    /// The photograph's Exif for a frame caption; empty when it has none.
    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts
    func close(_ photo: EditorPhoto) async
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

    static func formatLabel(for url: URL) -> String? {
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
