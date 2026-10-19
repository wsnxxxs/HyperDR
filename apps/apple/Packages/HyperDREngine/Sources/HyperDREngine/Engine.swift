import Foundation
import HyperDREngineCore

public struct EngineConfiguration: Sendable {
    public var cacheDirectory: URL?
    public var memoryBudgetBytes: UInt64
    public var heicTileWorkers: Int
    var hevcOverride: String?
    public init(cacheDirectory: URL? = nil, memoryBudgetBytes: UInt64 = 0, heicTileWorkers: Int = 0) {
        self.cacheDirectory = cacheDirectory
        self.memoryBudgetBytes = memoryBudgetBytes
        self.heicTileWorkers = heicTileWorkers
    }
}

/// A thread-safe engine handle. The synchronous static APIs are pure computation,
/// take microseconds to milliseconds, and may be called from any thread.
/// I/O, decode, inference and export run on a dedicated concurrent queue.
public final class Engine: @unchecked Sendable {
    let pointer: OpaquePointer
    public static var abiVersion: UInt32 { hyperdr_abi_version() }
    public static var version: String { String(cString: hyperdr_version()) }

    /// May initialize embedded model runtimes, so creation is asynchronous.
    public init(configuration: EngineConfiguration = .init()) async throws {
        let handle = try await EngineExecutor.run { _ in
            var config: [String: JSONValue] = [
                "memory_budget_bytes": .number(Double(configuration.memoryBudgetBytes)),
                "heic_tile_workers": .number(Double(configuration.heicTileWorkers))]
            if let override = configuration.hevcOverride { config["hevc_override"] = .string(override) }
            if let directory = configuration.cacheDirectory { config["cache_directory"] = .string(directory.path) }
            var output: OpaquePointer?
            var error: UnsafeMutablePointer<hyperdr_error>?
            let status = try encodeJSON(config).withCString { hyperdr_engine_create($0, &output, &error) }
            try checkStatus(status, error)
            guard let output else { throw HyperDRError(code: "internal_error", message: "Missing engine handle") }
            return EngineHandle(output)
        }
        pointer = handle.take()
    }
    deinit { hyperdr_engine_destroy(pointer) }

    public static func schema() throws -> SettingsSchema {
        let bytes = try jsonResult { hyperdr_schema_json($0, $1) }
        var result = try decodeJSON(SettingsSchema.self, bytes)
        result.rawJSON = bytes
        return result
    }
    public static func curve(settings: [String: JSONValue], samples: Int = 256) throws -> Data {
        guard (2...4096).contains(samples) else {
            throw HyperDRError(code: "invalid_options", message: "Samples must be between 2 and 4096")
        }
        return try encodeJSON(settings).withCString { input in
            try jsonResult { hyperdr_curve_json(input, UInt32(samples), $0, $1) }
        }
    }
    public static func normalize(_ editOptions: [String: JSONValue]) throws -> EngineRequest {
        let bytes = try encodeJSON(editOptions).withCString { input in
            try jsonResult { hyperdr_normalize_options(input, $0, $1) }
        }
        return try decodeJSON(EngineRequest.self, bytes)
    }
    public static func commandLine(_ request: EngineRequest) throws -> [String] {
        let bytes = try encodeJSON(request).withCString { input in
            try jsonResult { hyperdr_command_line(input, $0, $1) }
        }
        return try decodeJSON([String].self, bytes)
    }
    public func capabilities() async throws -> Capabilities {
        try await EngineExecutor.run { _ in
            let bytes = try jsonResult { hyperdr_capabilities(self.pointer, $0, $1) }
            var result = try decodeJSON(Capabilities.self, bytes)
            result.rawJSON = bytes
            return result
        }
    }
    /// Full decode; this ABI has no native cancellation argument. Cancellation
    /// is checked before dispatch and before returning the decoded result.
    public func probe(_ url: URL) async throws -> ProbeResult {
        try await EngineExecutor.run { _ in
            let bytes = try url.path.withCString { path in
                try jsonResult { hyperdr_probe(self.pointer, path, $0, $1) }
            }
            var result = try decodeJSON(ProbeResult.self, bytes)
            result.rawJSON = bytes
            return result
        }
    }
    /// Metadata I/O runs off the cooperative pool; this ABI has no cancel argument.
    public func rawMetadata(_ url: URL) async throws -> RawMetadata {
        try await EngineExecutor.run { _ in
            let bytes = try url.path.withCString { path in
                try jsonResult { hyperdr_raw_metadata(self.pointer, path, $0, $1) }
            }
            var result = try decodeJSON(RawMetadata.self, bytes)
            result.rawJSON = bytes
            return result
        }
    }
    /// Lightweight, thread-safe and lazy: only copies paths/configuration into a
    /// new session. It performs no file I/O, decode or model initialization.
    public func openPreview(source: URL, sha256: String? = nil) throws -> PreviewSession {
        var output: OpaquePointer?
        var error: UnsafeMutablePointer<hyperdr_error>?
        let status = source.path.withCString { path in
            if let sha256 { return sha256.withCString { hyperdr_preview_open(pointer, path, $0, &output, &error) } }
            return hyperdr_preview_open(pointer, path, nil, &output, &error)
        }
        try checkStatus(status, error)
        guard let output else { throw HyperDRError(code: "internal_error", message: "Missing preview handle") }
        return PreviewSession(pointer: output)
    }
    public func convert(_ request: EngineRequest,
                        events: (@Sendable (ConvertEvent) -> Void)? = nil) async throws -> ConvertReport {
        try await EngineExecutor.run { cancellation in
            let box = EventSink(events)
            let bytes = try encodeJSON(request).withCString { input in
                try withExtendedLifetime(box) {
                    try jsonResult { hyperdr_convert(self.pointer, input, deliverEvent,
                        Unmanaged.passUnretained(box).toOpaque(), cancellation.pointer, $0, $1) }
                }
            }
            let report = try decodeJSON(ReportDocument.self, bytes)
            return ConvertReport(json: bytes, files: report.files)
        }
    }
}

// Own the just-created handle across continuation cancellation/error, until the
// Engine initializer takes ownership. No native handle leaks on cancelled init.
private final class EngineHandle: @unchecked Sendable {
    private var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    func take() -> OpaquePointer { let value = pointer!; pointer = nil; return value }
    deinit { if let pointer { hyperdr_engine_destroy(pointer) } }
}

private final class EventSink {
    let receive: (@Sendable (ConvertEvent) -> Void)?
    init(_ receive: (@Sendable (ConvertEvent) -> Void)?) { self.receive = receive }
}
private let deliverEvent: hyperdr_event_fn = { user, json in
    guard let user, let json else { return }
    let sink = Unmanaged<EventSink>.fromOpaque(user).takeUnretainedValue()
    let bytes = Data(bytes: json, count: strlen(json))
    if let event = try? JSONDecoder().decode(ConvertEvent.self, from: bytes) { sink.receive?(event) }
}
