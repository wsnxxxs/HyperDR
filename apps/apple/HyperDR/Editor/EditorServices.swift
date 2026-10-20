import CoreGraphics
import Foundation
import HyperDREngine
import HyperDRKit
import HyperDRRender
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
    /// Renders the open photo for the editor (`RecipeEditor`): previews,
    /// details, scopes and thumbnails. One per services object.
    var rendering: any EditorRendering { get }
    func displayUpdates() -> AsyncStream<DisplayState>
    /// The photograph's Exif for a frame caption; empty when it has none.
    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts
    func close(_ photo: EditorPhoto) async
    /// Starts a recipe export (P7-3b); its events follow on `exportEvents`.
    func startExport(_ photo: EditorPhoto, job: RecipeExportJob, destination: URL?) async throws -> EditorExportTicket
    /// The open photo's file as its session recorded it, which an export renders from.
    func sourceRevision(_ photo: EditorPhoto) async throws -> RecipeSourceRevision
    func exportThumbnail(_ photo: EditorPhoto, version: String) async -> CGImage?
    func exportEvents(_ job: String) -> AsyncStream<EditorExportEvent>
    func cancelAllExports() async
    func hasExportActivity() async -> Bool
    func exports(for photo: EditorPhoto) async throws -> [ExportHistoryItem]
    func exportTimingHistory() async -> [ExportTimingSample]
    func suggestedFileName(_ photo: EditorPhoto, encoding: String) async throws -> String
    func validateDestination(_ url: URL, expectedExtension: String) async throws
    func saveExport(_ photo: EditorPhoto, export: String, destination: URL?) async throws -> SavedLocation
    /// A copy of one retained version's file, in a folder of its own, to hand to
    /// another app (drag, share). `fileName` is the name the receiver sees.
    func transferFile(_ photo: EditorPhoto, export: String, fileName: String?) async throws -> URL
    /// Points an open photo whose file has moved at the file the user chose.
    /// The same content keeps the session (and the handle); anything else
    /// throws `source_different`.
    func relink(_ photo: EditorPhoto, to url: URL) async throws -> EditorPhoto
    func exportFolder() async -> ExportFolder
    func setExportFolder(_ url: URL) async throws -> ExportFolder
    func encodingCapabilities() async throws -> EditorCapabilities
    func aboutInformation() async -> AboutInformation
    func diagnostics() async -> String
    func lutEntries() async -> [LUTItem]
    /// The `.cube` text of a library LUT, for the renderer.
    func lutCube(_ id: String) async throws -> String
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
    /// A remembered photo that can no longer be opened (`source_missing`),
    /// with the name it had when the name could be read.
    case unavailable(UserFacingError, name: String?)
}

/// One opened photo. `handle` makes every open distinct, so closing an
/// earlier open of the same file never closes a later one.
///
/// Equality and hashing look at `handle` only. A photo reconnected to a moved
/// file keeps its handle but gets a new `url` and `name`, and every task and
/// cache keyed on "the open photo" must carry on across that. So never use the
/// photo itself as an id to notice a rename (`onChange(of: photo)`, `.task(id:)`);
/// compare `url` or `name` explicitly, or use `photoSerial`.
struct EditorPhoto: Hashable {
    var url: URL
    var name: String
    let formatLabel: String
    var byteCount: Int64
    var handle = UUID()

    /// The handle is the identity: a photo reconnected to a moved file keeps
    /// it, so everything keyed on the open photo carries on.
    static func == (lhs: EditorPhoto, rhs: EditorPhoto) -> Bool { lhs.handle == rhs.handle }
    func hash(into hasher: inout Hasher) { hasher.combine(handle) }

    var openingDocument: DocumentState {
        DocumentState(name: name, formatLabel: formatLabel, byteCount: byteCount,
                      pixelSize: nil, phase: .opening, isRefreshing: false,
                      source: nil, previewError: nil)
    }
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
    var openFailures: [URL: UserFacingError] = [:]
    var restoreResult = RestoreResult.none
    let preferences: UserDefaults
    private let preferencesName: String
    /// Debug builds render through `FakeEditorRendering` (configure it per
    /// test); release builds have no fake renderer and open nothing.
    let rendering: any EditorRendering
    var versionThumbnailHandler: ((EditorPhoto, String) async -> CGImage?)?
    private(set) var versionThumbnailCalls: [String] = []
    var exportStartHandler: (() async throws -> Void)?
    var exportCancelHandler: (() async -> Void)?
    var exportSaveHandler: ((String, URL?) async throws -> SavedLocation)?
    var relinkHandler: ((URL) async throws -> EditorPhoto)?
    private(set) var relinkCalls: [URL] = []
    var transferHandler: ((String, String?) async throws -> URL)?
    private(set) var transferCalls: [(export: String, fileName: String?)] = []
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
    private(set) var exportCalls: [(photo: EditorPhoto, job: RecipeExportJob, destination: URL?)] = []
    private(set) var saveCalls: [(String, URL?)] = []
    private(set) var exportCancelCount = 0
    private(set) var activeExport = false
    private var exportSinks: [String: AsyncStream<EditorExportEvent>.Continuation] = [:]
    private(set) var startCount = 0
    private(set) var closed: [EditorPhoto] = []
    private var displays: [UUID: AsyncStream<DisplayState>.Continuation] = [:]

    init(openDelay: Duration = .milliseconds(30), rendering: (any EditorRendering)? = nil) {
        self.openDelay = openDelay
        #if DEBUG
        self.rendering = rendering ?? FakeEditorRendering()
        #else
        self.rendering = rendering ?? UnavailableEditorRendering(reason: "No renderer in this build")
        #endif
        (preferences, preferencesName) = UserDefaults.ephemeral()
    }

    #if DEBUG
    /// The fake renderer, when this services object uses one.
    var fakeRendering: FakeEditorRendering? { rendering as? FakeEditorRendering }
    #endif

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

}

extension FakeEditorServices {
    func startExport(_ photo: EditorPhoto, job: RecipeExportJob, destination: URL?) async throws -> EditorExportTicket {
        exportCalls.append((photo, job, destination)); activeExport = true
        do { try await exportStartHandler?(); try Task.checkCancellation() }
        catch { activeExport = false; throw error }
        return EditorExportTicket(job: "fake-job")
    }
    func exportEvents(_ job: String) -> AsyncStream<EditorExportEvent> {
        AsyncStream { exportSinks[job] = $0 }
    }
    func exportThumbnail(_ photo: EditorPhoto, version: String) async -> CGImage? {
        versionThumbnailCalls.append(version)
        return await versionThumbnailHandler?(photo, version)
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
    func saveExport(_ photo: EditorPhoto, export: String, destination: URL?) async throws -> SavedLocation {
        saveCalls.append((export, destination))
        if let exportSaveHandler { return try await exportSaveHandler(export, destination) }
        return SavedLocation(fileName: destination?.lastPathComponent ?? "saved.heic", folderLabel: folder.label)
    }
    func relink(_ photo: EditorPhoto, to url: URL) async throws -> EditorPhoto {
        relinkCalls.append(url)
        guard let relinkHandler else { throw UserFacingError(code: "source_different") }
        return try await relinkHandler(url)
    }
    func transferFile(_ photo: EditorPhoto, export: String, fileName: String?) async throws -> URL {
        transferCalls.append((export, fileName))
        guard let transferHandler else { throw UserFacingError(code: "source_missing") }
        return try await transferHandler(export, fileName)
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
    /// A 2³ identity cube whose title is the id, so each library item has its own hash.
    func lutCube(_ id: String) async throws -> String {
        guard library.contains(where: { $0.id == id }) else { throw UserFacingError(code: "lut_invalid") }
        return "TITLE \"\(id)\"\nLUT_3D_SIZE 2\n" + (0..<8).map { i in
            "\(i & 1) \((i >> 1) & 1) \(i >> 2)" }.joined(separator: "\n") + "\n"
    }
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
