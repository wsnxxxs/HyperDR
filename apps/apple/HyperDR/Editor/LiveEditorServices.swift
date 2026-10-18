import AppKit
import Foundation
import HyperDREngine
import HyperDRKit
import UniformTypeIdentifiers

/// The editor's service boundary backed by the native Kit.
@MainActor final class LiveEditorServices: EditorServices {
    /// What the app does with the composition root's cleanup lifecycle;
    /// injectable so tests can observe it.
    struct Lifecycle {
        var start: @MainActor (HyperDRKit) async -> Void = { await $0.start() }
        var stop: @MainActor (HyperDRKit) -> Void = { $0.stop() }
    }

    /// The Web editor's default output; the export interface (M3) makes it a
    /// workflow choice.
    static let encoding = "adaptive"

    private(set) var engineStatus: EngineStatus = .starting
    private(set) var displayState = DisplayState(screenName: "", currentHeadroom: 1,
                                                 potentialHeadroom: 1, gainWeight: nil)
    /// Long edge the next preview requests use; the model sets it from the
    /// canvas tier (`EditDefaults.previewEdge`).
    let preferences: UserDefaults
    private struct PendingSubmission {
        let handle: UUID
        let request: PreviewRequest
    }
    private var submitContinuation: AsyncStream<PendingSubmission>.Continuation?
    private var submitPump: Task<Void, Never>?
    private var latestRequests: [UUID: PreviewRequest] = [:]

    private struct Record {
        let session: PhotoSession
        var base: EditOptions
        var reference: PreviewFrame?
        var edited: PreviewFrame?
        // The task is also the cached result, including an empty result. Store
        // it before the first suspension so concurrent callers share one read.
        var captureFacts: Task<CaptureFacts, Never>?
    }

    private let readCaptureFacts: @Sendable (URL) -> CaptureFacts
    private let formats: InputFormats?
    private let openableTypes: [UTType]
    private let lifecycle: Lifecycle
    private let kitTask: Task<HyperDRKit, Error>
    private(set) var kit: HyperDRKit?
    private var records: [UUID: Record] = [:]
    private var engineObservers: [UUID: AsyncStream<EngineStatus>.Continuation] = [:]
    private var displayObservers: [UUID: AsyncStream<DisplayState>.Continuation] = [:]
    private var started = false
    private var stopped = false
    private var terminationObserver: (any NSObjectProtocol)?

    init(configuration: KitConfiguration = KitConfiguration(), preferences: UserDefaults = .standard, lifecycle: Lifecycle = Lifecycle(),
         readCaptureFacts: @escaping @Sendable (URL) -> CaptureFacts = { CaptureFacts.read($0) },
         makeKit: @escaping @Sendable (KitConfiguration) async throws -> HyperDRKit = {
             try await HyperDRKit(configuration: $0)
         }) {
        // The schema is a pure, synchronous engine call: the open panel and
        // drag checks work before the engine itself has started.
        let formats = try? InputFormats(schema: Engine.schema())
        self.readCaptureFacts = readCaptureFacts
        self.formats = formats
        openableTypes = formats?.contentTypes ?? []
        self.lifecycle = lifecycle
        self.preferences = preferences
        kitTask = Task.detached { try await makeKit(configuration) }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        Task { [weak self] in await self?.finishStarting() }
    }

    isolated deinit {
        submitPump?.cancel()
        submitContinuation?.finish()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: - Engine and lifecycle

    private func finishStarting() async {
        do {
            let kit = try await kitTask.value
            guard !stopped else { kit.stop(); return }
            self.kit = kit
            installSubmitPump(kit)
            setEngine(.ready(version: Engine.version))
        } catch {
            setEngine(.failed(UserFacingError(code: "engine_unavailable",
                                              detail: String(describing: error))))
        }
    }

    private func setEngine(_ status: EngineStatus) {
        engineStatus = status
        for observer in engineObservers.values { observer.yield(status) }
    }

    /// The current status, then every change.
    func engineUpdates() -> AsyncStream<EngineStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(engineStatus)
            engineObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.engineObservers.removeValue(forKey: id) }
            }
        }
    }

    private func requireKit() async throws -> HyperDRKit {
        if let kit { return kit }
        do { return try await kitTask.value }
        catch {
            throw UserFacingError(code: "engine_unavailable", detail: String(describing: error))
        }
    }

    /// The editor scene started: begin the startup and hourly cleanup once.
    /// Repeated calls (a reopened window) do nothing.
    func start() async {
        guard !started else { return }
        started = true
        guard let kit = try? await requireKit(), !stopped else { return }
        await lifecycle.start(kit)
    }

    /// The app is terminating. Safe to call more than once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        submitContinuation?.finish()
        submitPump?.cancel()
        if let kit { lifecycle.stop(kit) }
    }

    // MARK: - Formats

    var openableContentTypes: [UTType] { openableTypes }

    func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return openableTypes.contains(type)
    }

    func placeholder(for url: URL) -> EditorPhoto {
        EditorPhoto(url: url, name: url.lastPathComponent,
                    formatLabel: Self.formatLabel(for: url), byteCount: 0)
    }

    /// The label shown while a file opens, from its type alone (no I/O); the
    /// session's classified format replaces it once open.
    static func formatLabel(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "" }
        if type.conforms(to: .rawImage) { return "RAW" }
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .png) { return "PNG" }
        if type.conforms(to: .tiff) { return "TIFF" }
        if let avif = UTType("public.avif"), type.conforms(to: avif) { return "AVIF" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "HEIC" }
        return ""
    }

    // MARK: - Sessions

    func open(_ url: URL) async throws -> EditorPhoto {
        let kit = try await requireKit()
        let session: PhotoSession
        do { session = try await kit.sessions.open(url) }
        catch { throw UserFacingError.service(error) }
        return try await adopt(session, kit: kit)
    }

    /// The photo remembered from the last launch, attached and ready for the
    /// same reference + edit flow as a fresh open.
    func restoreLast() async -> RestoreResult {
        guard let kit = try? await requireKit() else { return .none }
        switch await kit.sessions.restoreLastOutcome() {
        case .none: return .none
        case .unavailable(let error): return .unavailable(UserFacingError(error))
        case .restored(let session):
            do { return .restored(try await adopt(session, kit: kit)) }
            catch { return .unavailable(UserFacingError.service(error)) }
        }
    }

    private func adopt(_ session: PhotoSession, kit: HyperDRKit) async throws -> EditorPhoto {
        let photo = EditorPhoto(url: session.sourceURL, name: session.displayName,
                                formatLabel: session.format.displayLabel, byteCount: session.byteCount)
        let workflow = EditDefaults.initial(encoding: Self.encoding, sourceDomain: nil, unadjusted: nil)
        records[photo.handle] = Record(session: session, base: workflow)
        do {
            try await kit.previews.attach(session)
            try Task.checkCancellation()
            return photo
        } catch {
            await close(photo)
            throw UserFacingError.service(error)
        }
    }

    func close(_ photo: EditorPhoto) async {
        guard let record = records.removeValue(forKey: photo.handle) else { return }
        record.captureFacts?.cancel()
        latestRequests.removeValue(forKey: photo.handle)
        let kit = try? await requireKit()
        guard let kit, !records.values.contains(where: { $0.session.id == record.session.id }) else { return }
        await kit.previews.detach(record.session.id)
        // A new adoption may have arrived during detach; preserve its scope.
        guard !records.values.contains(where: { $0.session.id == record.session.id }) else { return }
        await kit.sessions.close(record.session.id)
    }

    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts {
        guard let record = records[photo.handle] else { return CaptureFacts() }
        if let cached = record.captureFacts { return await cached.value }
        let url = record.session.sourceURL
        let read = readCaptureFacts
        let task = Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return read(url)
        }
        records[photo.handle]?.captureFacts = task
        return await task.value
    }

    // MARK: - Previews

    /// The frames the canvas should draw for a photo (reference SDR base and
    /// the latest edit).
    func frames(for photo: EditorPhoto) -> (reference: PreviewFrame?, edited: PreviewFrame?) {
        let record = records[photo.handle]
        return (record?.reference, record?.edited)
    }

    func previews(for photo: EditorPhoto, includingReference: Bool,
                  adjustments: [String: Double], maxEdge: Int) -> AsyncStream<EditorPreviewEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                await self?.render(photo, includingReference: includingReference,
                                   adjustments: adjustments, maxEdge: maxEdge, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func render(_ photo: EditorPhoto, includingReference: Bool, adjustments: [String: Double], maxEdge: Int,
                        into continuation: AsyncStream<EditorPreviewEvent>.Continuation) async {
        guard let kit, let record = records[photo.handle] else {
            continuation.yield(.failed(UserFacingError(code: "source_missing")))
            return
        }
        let id = record.session.id
        // Subscribe before submitting so the result cannot be missed.
        let events = kit.previews.events(for: id)
        do {
            var base = record.base
            if includingReference {
                // photo.js: neutral settings, no model; the adapter supplies
                // blend highlight recovery.
                var options = EditDefaults.reference(encoding: Self.encoding, workflow: base)
                options["useModel"] = .bool(false)
                let result = try await kit.previews.render(PreviewRequest(session: id, options: options,
                    maxEdge: maxEdge, purpose: .reference))
                try Task.checkCancellation()
                guard records[photo.handle] != nil else { throw CancellationError() }
                guard result.sourceDigest == record.session.sha256 else {
                    throw HyperDRError(code: "source_missing", message: "Source changed while opening")
                }
                let metadata = result.frame.metadata
                base = EditDefaults.initial(encoding: Self.encoding, sourceDomain: metadata.inputDomain,
                                            unadjusted: metadata.unadjusted.values)
                records[photo.handle]?.base = base
                records[photo.handle]?.reference = result.frame
                continuation.yield(.reference(Self.preview(result.frame)))
            }
            for (key, value) in adjustments { base[key] = .number(value) }
            let request = PreviewRequest(session: id, options: base, maxEdge: maxEdge, purpose: .edit)
            await kit.previews.submit(request)
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .finished(let result) where result.request == request:
                    guard records[photo.handle] != nil else { throw CancellationError() }
                    guard result.sourceDigest == record.session.sha256 else {
                        throw HyperDRError(code: "source_missing", message: "Source changed while opening")
                    }
                    records[photo.handle]?.edited = result.frame
                    continuation.yield(.edited(Self.preview(result.frame)))
                    return
                case .failed(let failed, let error) where failed == request:
                    continuation.yield(.failed(UserFacingError(error)))
                    return
                case .superseded(let superseded) where superseded == request:
                    return
                default:
                    continue
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            continuation.yield(.failed(UserFacingError.service(error)))
        }
    }

    static func preview(_ frame: PreviewFrame) -> EditorPreview {
        let metadata = frame.metadata
        return EditorPreview(
            pixelSize: PixelSize(width: metadata.sourceWidth ?? metadata.width,
                                 height: metadata.sourceHeight ?? metadata.height),
            source: SourceSummary(domain: InputDomain(rawValue: metadata.inputDomain) ?? .unknown,
                                  colorName: metadata.sourceColor.name,
                                  degradationReasons: metadata.degradationReasons),
            hasGain: frame.isCompact || metadata.headroomStops > 0,
            gainWeight: metadata.gainWeight, frame: frame)
    }

    private func installSubmitPump(_ kit: HyperDRKit) {
        guard submitPump == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: PendingSubmission.self,
            bufferingPolicy: .bufferingNewest(1))
        submitContinuation = continuation
        submitPump = Task { [weak self] in
            for await pending in stream {
                guard !Task.isCancelled else { return }
                guard let self, records[pending.handle] != nil,
                      latestRequests[pending.handle] == pending.request else { continue }
                await kit.previews.submit(pending.request)
            }
        }
    }

    func submit(_ photo: EditorPhoto, adjustments: [String: Double], maxEdge: Int) {
        guard let record = records[photo.handle], let kit, !stopped else { return }
        installSubmitPump(kit)
        var options = record.base
        for (key, value) in adjustments { options[key] = .number(value) }
        let request = PreviewRequest(session: record.session.id, options: options, maxEdge: maxEdge,
                                     submissionID: UUID())
        latestRequests[photo.handle] = request
        submitContinuation?.yield(PendingSubmission(handle: photo.handle, request: request))
    }

    func refreshes(for photo: EditorPhoto) -> AsyncStream<EditorRefreshEvent> {
        guard let kit, let record = records[photo.handle] else { return AsyncStream { $0.finish() } }
        let events = kit.previews.events(for: record.session.id)
        return AsyncStream { continuation in
            let observer = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self, records[photo.handle] != nil else { break }
                    switch event {
                    case .finished(let result) where result.request.purpose == .edit:
                        guard result.sourceDigest == record.session.sha256 else {
                            continuation.yield(.sourceReplaced); continuation.finish(); return
                        }
                        records[photo.handle]?.edited = result.frame
                        continuation.yield(.edited(Self.preview(result.frame),
                            isLatest: latestRequests[photo.handle] == result.request))
                    case .failed(let request, let error) where latestRequests[photo.handle] == request:
                        continuation.yield(.failed(UserFacingError(error)))
                    case .superseded(let request) where request.purpose == .edit:
                        continuation.yield(.superseded(isLatest: latestRequests[photo.handle] == request))
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in observer.cancel() }
        }
    }

    // MARK: - Display

    func displayUpdates() -> AsyncStream<DisplayState> {
        // The canvas reports headroom to the model directly; nothing else
        // changes the display state yet (A3 tracks it per frame).
        let id = UUID()
        return AsyncStream { continuation in
            displayObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.displayObservers.removeValue(forKey: id) }
            }
        }
    }
}


private extension PreviewMetadata.Unadjusted {
    var values: [String: Double] {
        ["brightness": brightness, "hdrStrength": hdrStrength, "hdrRange": hdrRange,
         "areaCoverage": areaCoverage, "lutStrength": lutStrength]
    }
}
