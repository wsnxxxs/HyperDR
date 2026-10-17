import Foundation
import UniformTypeIdentifiers

// App-internal boundary. A2 supplies live services without changing Views.
@MainActor protocol EditorServices: AnyObject {
    var engineStatus: EngineStatus { get }
    var displayState: DisplayState { get }
    var openableContentTypes: [UTType] { get }
    func canOpen(_ url: URL) -> Bool
    func placeholder(for url: URL) -> EditorPhoto
    func open(_ url: URL) async throws -> EditorPhoto
    func previews(for photo: EditorPhoto, includingReference: Bool,
                  adjustments: [String: Double]) -> AsyncStream<EditorPreviewEvent>
    func displayUpdates() -> AsyncStream<DisplayState>
    /// The photograph's Exif for a frame caption; empty when it has none.
    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts
    func close(_ photo: EditorPhoto) async
}

struct EditorPhoto: Equatable {
    let url: URL
    let name: String
    let formatLabel: String
    let byteCount: Int64

    var openingDocument: DocumentState {
        DocumentState(name: name, formatLabel: formatLabel, byteCount: byteCount,
                      pixelSize: nil, phase: .opening, isRefreshing: false,
                      source: nil, previewError: nil)
    }
}

struct EditorPreview {
    let pixelSize: PixelSize
    let source: SourceSummary
    let hasGain: Bool
}

enum EditorPreviewEvent {
    case reference(EditorPreview), edited(EditorPreview), failed(UserFacingError)
}

@MainActor final class FakeEditorServices: EditorServices {
    var engineStatus: EngineStatus = .ready(version: "fixture-v1")
    var displayState = DisplayState(screenName: "", currentHeadroom: 2.4,
                                    potentialHeadroom: 10.15, gainWeight: nil)
    var openDelay: Duration
    var previewDelay: Duration
    var openFailures: [URL: UserFacingError] = [:]
    var previewFailure: UserFacingError?
    var preview = EditorPreview(pixelSize: PixelSize(width: 6000, height: 4000),
        source: SourceSummary(domain: .sceneReferred, colorName: "Display P3", degradationReasons: []),
        hasGain: true)
    private(set) var renderedPurposes: [Bool] = [] // true = reference, false = edit
    private(set) var receivedAdjustments: [[String: Double]] = []
    private var displays: [UUID: AsyncStream<DisplayState>.Continuation] = [:]

    init(openDelay: Duration = .milliseconds(30), previewDelay: Duration = .milliseconds(30)) {
        self.openDelay = openDelay
        self.previewDelay = previewDelay
    }

    var openableContentTypes: [UTType] {
        [.jpeg, .png, .tiff, .heic, .heif] +
            ["public.avif", "public.camera-raw-image"].compactMap { UTType($0) }
    }

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

    func previews(for photo: EditorPhoto, includingReference: Bool,
                  adjustments: [String: Double]) -> AsyncStream<EditorPreviewEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    if includingReference {
                        try await Task.sleep(for: previewDelay)
                        try Task.checkCancellation()
                        if let error = previewFailure {
                            continuation.yield(.failed(error)); continuation.finish(); return
                        }
                        renderedPurposes.append(true)
                        continuation.yield(.reference(preview))
                    }
                    try await Task.sleep(for: previewDelay)
                    try Task.checkCancellation()
                    if let error = previewFailure { continuation.yield(.failed(error)) }
                    else {
                        renderedPurposes.append(false)
                        receivedAdjustments.append(adjustments)
                        continuation.yield(.edited(preview))
                    }
                } catch { /* Stream termination owns cancellation. */ }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
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

    func close(_ photo: EditorPhoto) async {}
}
