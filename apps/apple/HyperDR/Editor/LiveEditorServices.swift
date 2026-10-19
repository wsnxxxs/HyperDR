import AppKit
import Foundation
import HyperDREngine
import HyperDRKit
import UniformTypeIdentifiers
import os

/// The editor's service boundary backed by the native Kit.
@MainActor final class LiveEditorServices: EditorServices {
    /// What the app does with the composition root's cleanup lifecycle;
    /// injectable so tests can observe it.
    struct Lifecycle {
        var start: @MainActor (HyperDRKit) async -> Void = { await $0.start() }
        var stop: @MainActor (HyperDRKit) -> Void = { $0.stop() }
    }

    private(set) var engineStatus: EngineStatus = .starting
    private(set) var displayState = DisplayState(screenName: "", currentHeadroom: 1,
                                                 potentialHeadroom: 1, gainWeight: nil)
    /// Long edge the next preview requests use; the model sets it from the
    /// canvas tier (`EditDefaults.previewEdge`).
    let preferences: UserDefaults
    private struct PendingSubmission {
        let handle: UUID
        let request: PreviewRequest
        let trace: PreviewTrace?
    }
    private var submitContinuation: AsyncStream<PendingSubmission>.Continuation?
    private var submitPump: Task<Void, Never>?
    private var latestRequests: [UUID: PreviewRequest] = [:]

    private struct Record {
        let session: PhotoSession
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
        records[photo.handle] = Record(session: session)
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

    func previews(for photo: EditorPhoto, encoding: String,
                  maxEdge: Int) -> AsyncStream<EditorPreviewEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                await self?.render(photo, encoding: encoding, maxEdge: maxEdge, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func render(_ photo: EditorPhoto, encoding: String, maxEdge: Int,
                        into continuation: AsyncStream<EditorPreviewEvent>.Continuation) async {
        guard let kit, let record = records[photo.handle] else {
            continuation.yield(.failed(UserFacingError(code: "source_missing")))
            return
        }
        let id = record.session.id
        // Subscribe before submitting so the result cannot be missed.
        let events = kit.previews.events(for: id)
        do {
            // The neutral comparison frame: no model, the photo's own colour.
            let workflow = EditDefaults.initial(encoding: encoding, sourceDomain: nil, unadjusted: nil)
            let result = try await kit.previews.render(PreviewRequest(session: id,
                options: EditDefaults.reference(encoding: encoding, workflow: workflow),
                maxEdge: maxEdge, purpose: .reference))
            try Task.checkCancellation()
            guard records[photo.handle] != nil else { throw CancellationError() }
            guard result.sourceDigest == record.session.sha256 else {
                throw HyperDRError(code: "source_missing", message: "Source changed while opening")

            }
            records[photo.handle]?.reference = result.frame
            let reference = Self.preview(result.frame, trace: result.trace)
            continuation.yield(.reference(reference))
            let base = EditBaseline.initial(encoding: encoding, preview: reference)
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
                    continuation.yield(.edited(Self.preview(result.frame, trace: result.trace)))
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

    static func preview(_ frame: PreviewFrame, trace: PreviewTrace? = nil) -> EditorPreview {
        let metadata = frame.metadata
        return EditorPreview(
            pixelSize: PixelSize(width: metadata.sourceWidth ?? metadata.width,
                                 height: metadata.sourceHeight ?? metadata.height),
            source: SourceSummary(metadata),
            hasGain: frame.isCompact || metadata.headroomStops > 0,
            gainWeight: metadata.gainWeight, frame: frame,
            unadjusted: metadata.unadjusted.values,
            hasCaptureMetadata: metadata.hasCaptureMetadata, trace: trace)
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
                await PreviewTrace.$current.withValue(pending.trace) {
                    await kit.previews.submit(pending.request)
                }
            }
        }
    }

    func submit(_ photo: EditorPhoto, options: EditOptions, maxEdge: Int) {
        guard let record = records[photo.handle], let kit, !stopped else { return }
        installSubmitPump(kit)
        let request = PreviewRequest(session: record.session.id, options: options, maxEdge: maxEdge,
                                     submissionID: UUID())
        latestRequests[photo.handle] = request
        submitContinuation?.yield(PendingSubmission(handle: photo.handle, request: request, trace: PreviewTrace.current))
    }

    func renderDetail(_ photo: EditorPhoto, options: EditOptions, region: PreviewRegion,
                      original: Bool) async throws -> EditorPreview? {
        guard let kit, let record = records[photo.handle] else { throw UserFacingError(code: "source_missing") }
        let result = try await kit.previews.render(PreviewRequest(session: record.session.id,
            options: options, maxEdge: DetailPolicy.maxEdge, region: region,
            purpose: original ? .reference : .edit))
        try Task.checkCancellation()
        guard records[photo.handle] != nil else { throw CancellationError() }
        guard result.sourceDigest == record.session.sha256 else { throw EditorDetailError.sourceReplaced }
        return Self.preview(result.frame, trace: result.trace)
    }

    func refreshes(for photo: EditorPhoto) -> AsyncStream<EditorRefreshEvent> {
        guard let kit, let record = records[photo.handle] else { return AsyncStream { $0.finish() } }
        let events = kit.previews.events(for: record.session.id)
        return AsyncStream { continuation in
            let observer = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self, records[photo.handle] != nil else { break }
                    switch event {
                    case .finished(let result) where result.request.purpose == .edit && result.request.region == nil:
                        guard result.sourceDigest == record.session.sha256 else {
                            continuation.yield(.sourceReplaced); continuation.finish(); return
                        }
                        records[photo.handle]?.edited = result.frame
                        continuation.yield(.edited(Self.preview(result.frame, trace: result.trace),
                            isLatest: latestRequests[photo.handle] == result.request))
                    case .failed(let request, let error) where latestRequests[photo.handle] == request:
                        continuation.yield(.failed(UserFacingError(error)))
                    case .superseded(let request) where request.purpose == .edit && request.region == nil:
                        continuation.yield(.superseded(isLatest: latestRequests[photo.handle] == request))
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in observer.cancel() }
        }
    }

    // MARK: - AI

    func modelTable() -> ModelTable {
        guard let catalog = kit?.models else { return .unavailable }
        return ModelTable(runtimeReady: catalog.status.runtimeAvailable, defaultID: catalog.defaultID,
            models: catalog.models.map { entry in
                var key = "model.\(entry.id)"
                if case .string(let declared)? = entry.document["displayKey"] { key = declared }
                return ModelChoice(id: entry.id, name: entry.displayName, nameKey: key,
                    summaryKey: key + ".summary", isEnabled: entry.available,
                    requiresCapture: entry.document["requiresExif"] == .bool(true))
            })
    }

    func modelGainToken(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainToken {
        guard let kit, let record = records[photo.handle] else { throw UserFacingError(code: "source_missing") }
        do {
            return ModelGainToken(value: try await kit.previews.modelGainKey(session: record.session.id,
                                                                            options: options))
        } catch { throw UserFacingError.service(error) }
    }

    func computeModelGain(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainOutcome {
        guard let kit, let record = records[photo.handle] else { throw UserFacingError(code: "source_missing") }
        do {
            let result = try await kit.previews.modelGain(session: record.session.id, options: options)
            return ModelGainOutcome(token: ModelGainToken(value: result.key),
                                    missingCaptureFields: Self.missingCaptureFields(result.packet))
        } catch { throw UserFacingError.service(error) }
    }

    /// The capture fields a model fell back without, from the `HYPGAIN1`
    /// packet's `fallbackReason` (`missing_capture_fields:iso:f_number`).
    static func missingCaptureFields(_ packet: Data) -> [String] {
        let magic = Array("HYPGAIN1\n".utf8)
        guard packet.count >= 13, Array(packet.prefix(9)) == magic else { return [] }
        let size = packet.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 9, as: UInt32.self))) }
        guard size > 0, 13 + size <= packet.count,
              let header = try? JSONDecoder().decode([String: JSONValue].self,
                                                     from: packet.subdata(in: 13..<13 + size)),
              case .string(let reason)? = header["fallbackReason"] else { return [] }
        return ModelFallbackReason(engineReason: reason)?.missingCaptureFields.map(\.rawValue) ?? []
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

extension LiveEditorServices {
    private func exportSession(_ photo: EditorPhoto) throws -> SessionID {
        guard let record = records[photo.handle] else { throw UserFacingError(code: "session_expired") }
        return record.session.id
    }
    func startExport(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?, destination: URL?) async throws -> EditorExportTicket {
        let id = try exportSession(photo), kit = try await requireKit()
        let ticket = try await kit.jobs.start(session: id, options: options, frame: frame, destination: destination)
        return EditorExportTicket(job: ticket.job.rawValue, argv: ticket.argv)
    }
    func exportEvents(_ job: String) -> AsyncStream<EditorExportEvent> {
        guard let kit else { return AsyncStream { $0.finish() } }
        let events = kit.jobs.events(JobID(rawValue: job))
        return AsyncStream { sink in
            let task = Task {
                for await event in events {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .publishing: sink.yield(.finishing)
                    case .saving: sink.yield(.saving)
                    case .progress(let p): sink.yield(.progress(stage: p.phase, fraction: p.fraction, at: Date()))
                    case .log(let text): sink.yield(.log(text))
                    case .finished(let summary):
                        var result = await Task.detached { summary.result.map { ExportHistoryItem($0).version.result } }.value
                        if let saved = summary.saved {
                            result?.saved = Self.savedLocation(saved)
                        }
                        sink.yield(.finished(result: result, failure: summary.failure.map(UserFacingError.init)))
                    }
                }
                sink.finish()
            }
            sink.onTermination = { _ in task.cancel() }
        }
    }
    func cancelAllExports() async { if let kit = try? await requireKit() { await kit.jobs.cancelAll() } }
    func hasExportActivity() async -> Bool {
        guard let kit = try? await requireKit() else { return false }
        return await kit.jobs.activity != .idle
    }
    func commandLine(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?) async throws -> [String] {
        let id = try exportSession(photo), kit = try await requireKit()
        return try await kit.jobs.commandLine(session: id, options: options, frame: frame)
    }
    func exportKey(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?) async throws -> String {
        let id = try exportSession(photo), kit = try await requireKit()
        return try await kit.jobs.exportKey(session: id, options: options, frame: frame).rawValue
    }
    func exports(for photo: EditorPhoto) async throws -> [ExportHistoryItem] {
        let id = try exportSession(photo), kit = try await requireKit()
        // exports(for:) returns [] for an expired session; check it first.
        _ = try await kit.sessions.session(id)
        let records = await kit.sessions.exports(for: id)
        return await Task.detached { records.map(ExportHistoryItem.init) }.value
    }
    func exportTimingHistory() async -> [ExportTimingSample] {
        guard let kit = try? await requireKit() else { return [] }
        let records = await kit.sessions.recentExports()
        return await Task.detached { records.compactMap { ExportHistoryItem($0).timing } }.value
    }
    func suggestedFileName(_ photo: EditorPhoto, options: EditOptions) async throws -> String {
        let id = try exportSession(photo), kit = try await requireKit()
        return try await kit.jobs.suggestedFileName(session: id, options: options)
    }
    func validateDestination(_ url: URL, expectedExtension: String) async throws {
        try await requireKit().exportTarget.validateDestination(url, expectedExtension: expectedExtension)
    }
    private static func savedLocation(_ saved: SavedExport) -> SavedLocation {
        SavedLocation(fileName: saved.name, folderLabel: SavedLocation.label(displayName: saved.folderDisplayName), reveal: { saved.reveal() })
    }

    func saveExport(_ photo: EditorPhoto, export: String, destination: URL?) async throws -> SavedLocation {
        let id = try exportSession(photo), kit = try await requireKit(), version = ExportID(rawValue: export)
        let saved: SavedExport
        if let destination { saved = try await kit.exportTarget.save(session: id, export: version, to: destination) }
        else { saved = try await kit.exportTarget.save(session: id, export: version) }
        do { try await kit.sessions.markSaved(id, export: version, saved: SavedMark(fileName: saved.name, folderDisplayName: saved.folderDisplayName)) }
        catch { Logger(subsystem: "com.hyperdr.HyperDR", category: "Export").warning("Export saved but its history mark could not be persisted") }
        return Self.savedLocation(saved)
    }
    func exportFolder() async -> ExportFolder {
        guard let kit = try? await requireKit() else { return ExportFolder() }
        let folder = await kit.exportTarget.folder
        guard folder.ready else { return ExportFolder(label: folder.label, ready: false) }
        do {
            let snapshot = try await kit.exportTarget.captureFolder()
            let target = ExportFolderTarget(reveal: { try await kit.exportTarget.reveal(folder: snapshot) }) { [weak self, kit, snapshot] photo, export in
                guard let self else { throw UserFacingError(code: "engine_unavailable") }
                let id = try exportSession(photo), version = ExportID(rawValue: export)
                let saved = try await kit.exportTarget.save(session: id, export: version, folder: snapshot)
                do { try await kit.sessions.markSaved(id, export: version, saved: SavedMark(fileName: saved.name, folderDisplayName: saved.folderDisplayName)) }
                catch { Logger(subsystem: "com.hyperdr.HyperDR", category: "Export").warning("Export saved but its history mark could not be persisted") }
                return Self.savedLocation(saved)
            }
            return ExportFolder(label: snapshot.label, ready: true, target: target)
        } catch { return ExportFolder(label: folder.label, ready: false) }
    }
    func setExportFolder(_ url: URL) async throws -> ExportFolder {
        let kit = try await requireKit()
        _ = try await kit.exportTarget.setFolder(url)
        return await exportFolder()
    }
    func encodingCapabilities() async throws -> EditorCapabilities {
        let c = try await requireKit().capabilities
        return EditorCapabilities(encodings: Dictionary(uniqueKeysWithValues: c.encodings.map { ($0.id, .init(available: $0.available, reason: $0.reason)) }),
            main8: c.encoder?.main8 ?? false, main10: c.encoder?.main10 ?? false, encoderReason: c.encoder?.reason)
    }
    func exportFileURL(_ photo: EditorPhoto, export: String) async throws -> URL {
        let session = try exportSession(photo)
        return try await requireKit().sessions.resultURL(session, export: ExportID(rawValue: export))
    }
    func aboutInformation() async -> AboutInformation {
        AboutInformation(bundle: .main, engineABI: Engine.abiVersion)
    }
    func diagnostics() async -> String {
        guard let kit = try? await requireKit() else { return "" }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // The RAW OS build comes exclusively from engine preview metadata.
        return String(decoding: kit.capabilities.rawJSON, as: UTF8.self)
            + "\nmacOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    private func item(_ entry: LUTEntry) -> LUTItem {
        LUTItem(id: entry.id.rawValue, name: entry.name,
            input: LUTColorSpace(rawValue: entry.input.rawValue) ?? .srgb,
            output: LUTColorSpace(rawValue: entry.output.rawValue) ?? .srgb, byteCount: entry.byteCount)
    }
    func lutEntries() async -> [LUTItem] {
        guard let kit = try? await requireKit() else { return [] }
        return await kit.luts.entries().map(item)
    }
    func importLUT(_ url: URL) async throws -> LUTItem { item(try await requireKit().luts.importLUT(url)) }
    func applyLUT(_ id: String, to photo: EditorPhoto) async throws -> LUTItem {
        let session = try exportSession(photo)
        return item(try await requireKit().luts.apply(LUTID(rawValue: id), to: session))
    }
    func updateLUT(_ id: String, input: LUTColorSpace, output: LUTColorSpace) async throws -> LUTItem {
        item(try await requireKit().luts.update(LUTID(rawValue: id), input: LUTSpace(rawValue: input.rawValue)!, output: LUTSpace(rawValue: output.rawValue)!))
    }
    func removeLUT(_ id: String) async throws { try await requireKit().luts.remove(LUTID(rawValue: id)) }
}
