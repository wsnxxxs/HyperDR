import Foundation
import HyperDREngine
import os

public actor JobRunner {
    typealias Converter = @Sendable (EngineRequest, @escaping @Sendable (ConvertEvent) -> Void) async throws -> ConvertReport
    private struct Record {
        let id: JobID
        let session: SessionID
        var log: JobLog
        var done = false
        var cancelled = false
        var timedOut = false
        var committing = false
        var failure: HyperDRError?
        var result: ExportRecord?
        var saved: SavedExport?
        var hasDestination = false
        var stopSaving = false
        var delivery: Task<SavedExport, Error>?
        var task: Task<Void, Never>?
        var summary: JobSummary {
            JobSummary(id: id, session: session, done: done, cancelled: cancelled,
                timedOut: timedOut, failure: failure, result: result, saved: saved)
        }
    }
    private let target: ExportTarget
    private let sessions: SessionStore
    private let resolver: OptionResolver
    private let convert: Converter
    private let probe: @Sendable (URL) async throws -> (Int, Int)
    private let configuration: KitConfiguration
    private nonisolated let hub = JobEventHub()
    /// Covers preparation, conversion, publication and failed-output removal.
    private var admission: UUID?
    private var record: Record?
    private var preparation: Task<JobTicket, Error>?
    private let beforePublish: @Sendable () async -> Void
    /// Internal observation for tests that must establish a drain is actually
    /// waiting before releasing preparation/conversion/publication gates.
    private(set) var cancelAllWaiterCount = 0

    public var activity: JobActivity {
        guard admission != nil else { return .idle }
        if preparation != nil { return .preparing }
        guard let record, !record.done else { return .preparing }
        return record.committing ? .committing(record.id) : .running(record.id)
    }

    /// Cancellation waits for cleanup. Publication is an irreversible commit
    /// point: callers wait for it instead of cancelling an already-published result.
    public func cancelAll() async {
        cancelAllWaiterCount += 1
        defer { cancelAllWaiterCount -= 1 }
        if let preparation {
            preparation.cancel()
            _ = try? await preparation.value
        } else if let task = record?.task {
            if record?.hasDestination == true, record?.committing == true {
                record?.stopSaving = true
                record?.delivery?.cancel()
            } else if record?.committing != true {
                record?.cancelled = true
                task.cancel()
            }
            await task.value
        }
    }

    public func exportKey(session id: SessionID, options: EditOptions,
                          frame: ExportFrame? = nil) async throws -> ExportKey {
        let request = try resolver.resolveExport(options, session: await sessions.session(id))
        return try ExportKey(request: request, frame: frame.map { try ExportFrameRecord($0) })
    }

    public func suggestedFileName(session id: SessionID, options: EditOptions) async throws -> String {
        let photo = try await sessions.session(id)
        let request = try resolver.resolveExport(options, session: photo)
        return photo.sourceURL.deletingPathExtension().lastPathComponent + "-hyperdr." + (try Self.fileExtension(request))
    }

    /// Panel-v1 format ids, checked against actual engine filenames in tests.
    private static func fileExtension(_ request: EngineRequest) throws -> String {
        switch request.settings["encoding"]?.stringValue {
        case "sdr-tiff": "tif"
        case "sdr-jpeg", "iso-gainmap-jpeg": "jpg"
        case "avif-pq", "avif-hlg": "avif"
        case "adaptive", "pq", "hlg": "heic"
        default: throw HyperDRError(code: "invalid_options", message: "Unknown export encoding")
        }
    }

    public func commandLine(session id: SessionID, options: EditOptions,
                            frame: ExportFrame? = nil) async throws -> [String] {
        var request = try resolver.resolveExport(options, session: await sessions.session(id))
        if let frame { _ = try ExportFrameRecord(frame) }
        try request.setCommand("output", .string("<导出文件夹>"))
        try request.setCommand("report", .string("<导出文件夹>/report.json"))
        if frame != nil { try request.setCommand("frame", .string("<导出文件夹>/frame.json")) }
        var argv = try Engine.commandLine(request)
        argv[0] = "HyperDR"
        return argv
    }

    public init(configuration: KitConfiguration, schema: SettingsSchema,
                capabilities: Capabilities, sessions: SessionStore, engine: Engine) {
        self.init(configuration: configuration, sessions: sessions,
            resolver: OptionResolver(schema: schema, models: ModelCatalog(capabilities: capabilities),
                maxEdgeCeiling: configuration.previewMaxEdge,
                sessionLUTs: SessionLUTResolver(configuration: configuration)),
            probe: { url in let result = try await engine.probe(url); return (result.width, result.height) },
            convert: { request, events in try await engine.convert(request, events: events) })
    }

    init(configuration: KitConfiguration, sessions: SessionStore, resolver: OptionResolver,
         probe: @escaping @Sendable (URL) async throws -> (Int, Int),
         convert: @escaping Converter, beforePublish: @escaping @Sendable () async -> Void = {},
         exportTarget: ExportTarget? = nil) {
        self.target = exportTarget ?? ExportTarget(configuration: configuration, sessions: sessions)
        self.beforePublish = beforePublish
        self.configuration = configuration; self.sessions = sessions
        self.resolver = resolver; self.probe = probe; self.convert = convert
    }

    public func start(session id: SessionID, options: EditOptions,
                      frame: ExportFrame? = nil, destination: URL? = nil) async throws -> JobTicket {
        guard admission == nil else {
            throw HyperDRError(code: "convert_in_progress", message: "An export is already running")
        }
        let token = UUID()
        admission = token
        let task = Task { try await self.prepare(session: id, options: options, frame: frame, destination: destination, token: token) }
        preparation = task
        defer { if admission == token || admission == nil { preparation = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func prepare(session id: SessionID, options: EditOptions, frame: ExportFrame?, destination: URL?, token: UUID) async throws -> JobTicket {
        var pending: ExportID?
        do {
            let (photo, lease) = try await sessions.exportSource(id)
            var request = try resolver.resolveExport(options, session: photo)
            let destinationLease: SecurityScopeLease?
            if let destination {
                destinationLease = try await target.leaseDestination(destination, expectedExtension: Self.fileExtension(request))
            } else { destinationLease = nil }
            // Also validate command serialization before allocating a version.
            _ = try Engine.commandLine(request)
            if let frame {
                guard frame.spec["overlay"] == nil else { throw invalidFrame("Overlay must be supplied as PNG data") }
                let (width, height) = try await probe(photo.sourceURL)
                let layout = try Engine.frameLayout(frame: frame.spec, photoWidth: width, photoHeight: height)
                if let png = frame.overlayPNG {
                    guard layout.caption.width > 0, layout.caption.height > 0,
                          Self.pngSize(png) == [layout.caption.width, layout.caption.height] else {
                        throw invalidFrame("Caption PNG dimensions do not match the frame layout")
                    }
                }
            }
            try Task.checkCancellation()
            let frameRecord = try frame.map { try ExportFrameRecord($0) }
            let key = try ExportKey(request: request, frame: frameRecord)
            let version = try await sessions.prepareExport(id, options: options.values, frame: frameRecord, key: key)
            pending = version.id
            try Task.checkCancellation()
            try request.setCommand("output", .string(version.directory.path))
            try request.setCommand("report", .string(version.directory.appendingPathComponent("report.json").path))
            if let frame {
                var spec = frame.spec
                if let png = frame.overlayPNG {
                    try png.write(to: version.directory.appendingPathComponent("frame-caption.png"), options: .atomic)
                    spec["overlay"] = .string("frame-caption.png")
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let path = version.directory.appendingPathComponent("frame.json")
                try encoder.encode(spec).write(to: path, options: .atomic)
                try request.setCommand("frame", .string(path.path))
            }
            var argv = try Engine.commandLine(request)
            guard !argv.isEmpty else { throw invalidFrame("Missing command line") }
            argv[0] = "HyperDR"
            try Task.checkCancellation()
            if let previous = record { hub.forget(previous.id) }
            let job = JobID(rawValue: UUID().uuidString.lowercased())
            hub.begin(job)
            record = Record(id: job, session: id, log: JobLog(limit: configuration.maxJobLogCharacters))
            record?.hasDestination = destination != nil
            let task = Task { await self.run(job: job, session: id, export: version.id,
                request: request, lease: lease, destination: destination, destinationLease: destinationLease) }
            record?.task = task
            preparation = nil
            return JobTicket(job: job, export: version.id, argv: argv)
        } catch {
            if let pending { await sessions.discardExport(id, export: pending) }
            if admission == token { admission = nil }
            if error is CancellationError { throw HyperDRError(code: "cancelled", message: "Export preparation cancelled") }
            throw error
        }
    }

    public func cancel(_ id: JobID) async -> Bool {
        if record?.id == id, let delivery = record?.delivery {
            delivery.cancel()
            return true
        }
        guard record?.id == id, record?.done == false, record?.committing == false else { return false }
        record?.cancelled = true
        record?.task?.cancel()
        return true
    }
    public func read(_ id: JobID, offset: Int) async -> JobSnapshot? {
        guard let record, record.id == id else { return nil }
        let text = record.log.read(offset)
        return JobSnapshot(summary: record.summary, text: text.text,
            offset: record.log.end, logStart: record.log.start, truncated: text.truncated)
    }
    public nonisolated func events(_ id: JobID) -> AsyncStream<JobEvent> { hub.stream(id) }
    public func job(for session: SessionID) async -> JobSummary? {
        guard record?.session == session, record?.done == false else { return nil }
        return record?.summary
    }

    private func run(job: JobID, session: SessionID, export: ExportID,
                     request: EngineRequest, lease: SecurityScopeLease, destination: URL?,
                     destinationLease: SecurityScopeLease?) async {
        defer { lease.stop(); destinationLease?.stop() }
        // Engine callbacks synchronously enqueue into this single FIFO. Drain
        // it before publishing the terminal event, including on cancellation.
        let (stream, sink) = AsyncStream.makeStream(of: ConvertEvent.self)
        let drain = Task { for await event in stream { self.receive(event, job: job) } }
        let work = Task { try Task.checkCancellation(); return try await convert(request) { sink.yield($0) } }
        let timer = Task {
            do { try await Task.sleep(for: configuration.jobTimeout) } catch { return }
            self.timeout(job); work.cancel()
        }
        var report: ConvertReport?
        var failure: HyperDRError?
        do {
            report = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            failure = error as? HyperDRError ?? HyperDRError(
                code: error is CancellationError ? "cancelled" : "internal_error", message: String(describing: error))
        }
        timer.cancel(); sink.finish()
        // drain is independent of the cancelled runner task.
        await drain.value
        if record?.cancelled == true || record?.timedOut == true || Task.isCancelled {
            failure = HyperDRError(code: record?.timedOut == true ? "convert_timeout" : "cancelled",
                message: "Export cancelled")
        }
        if let report, failure == nil, !report.files.contains(where: { $0.success }) {
            let file = report.files.first(where: { !$0.skipped }) ?? report.files.first
            failure = HyperDRError(code: file?.errorCode ?? "export_failed",
                message: file?.message ?? "The conversion produced no successful output",
                detail: file?.detail)
        }
        if let report, failure == nil {
            // Publication is the commit point. After this actor turn cancel
            // returns false; a published version must never be called cancelled.
            record?.committing = true
            hub.emit(.publishing, id: job)
            await beforePublish()
            do { record?.result = try await sessions.publishExport(session, export: export, report: report) }
            catch { failure = error as? HyperDRError ?? HyperDRError(code: "internal_error", message: String(describing: error)) }
        }
        if let destination, failure == nil, record?.result != nil {
            hub.emit(.saving, id: job)
            do {
                if record?.stopSaving == true { throw CancellationError() }
                let delivery = Task { try await target.save(session: session, export: export, to: destination) }
                record?.delivery = delivery
                let saved = try await delivery.value
                let mark = SavedMark(fileName: saved.name, folderLabel: saved.folderLabel)
                record?.saved = saved
                record?.result?.saved = mark
                do { try await sessions.markSaved(session, export: export, saved: mark) }
                catch {
                    // Delivery already committed. A history-sidecar failure
                    // must not make the user save a second copy.
                    Logger(subsystem: "com.hyperdr.HyperDR", category: "Export")
                        .warning("Export delivered but its saved mark could not be persisted")
                }
            } catch {
                // The export remains valid history even if delivery fails or
                // is cancelled. A terminal success always means the chosen
                // file is already in place, never merely in the workspace.
                failure = error as? HyperDRError ?? HyperDRError(
                    code: error is CancellationError ? "cancelled" : "export_failed",
                    message: "Unable to save the completed export", detail: String(describing: error))
            }
            record?.delivery = nil
        }
        if record?.result == nil, failure != nil || report == nil {
            await sessions.discardExport(session, export: export)
        }
        record?.failure = failure
        record?.done = true
        record?.task = nil
        admission = nil
        if let summary = record?.summary { hub.emit(.finished(summary), id: job) }
    }
    private func receive(_ event: ConvertEvent, job: JobID) {
        guard record?.id == job, record?.done == false else { return }
        hub.emit(.progress(event), id: job)
        if !event.text.isEmpty {
            record?.log.append(event.text)
            hub.emit(.log(event.text), id: job)
        }
    }
    private func timeout(_ id: JobID) {
        if record?.id == id, record?.done == false { record?.timedOut = true }
    }
    private func invalidFrame(_ message: String) -> HyperDRError {
        HyperDRError(code: "invalid_options", message: message)
    }
    private static func pngSize(_ data: Data) -> [Int]? {
        let bytes = Array(data.prefix(24))
        guard bytes.count == 24, Array(bytes[0..<8]) == [137,80,78,71,13,10,26,10],
              Array(bytes[8..<16]) == [0,0,0,13,73,72,68,82] else { return nil }
        func value(_ start: Int) -> Int { bytes[start..<start+4].reduce(0) { ($0 << 8) | Int($1) } }
        return [value(16), value(20)]
    }
}
