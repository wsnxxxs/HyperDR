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
/// I/O, decode and packaging run on a dedicated concurrent queue.
public final class Engine: @unchecked Sendable {
    let pointer: OpaquePointer
    public static var abiVersion: UInt32 { hyperdr_abi_version() }
    public static var version: String { String(cString: hyperdr_version()) }

    /// Creates the native writer handle on its execution queue.
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

    /// Lightweight, thread-safe and lazy: only copies paths/configuration into a
    /// new session. It performs no file I/O, decode or model initialization.


}

// Own the just-created handle across continuation cancellation/error, until the
// Engine initializer takes ownership. No native handle leaks on cancelled init.
private final class EngineHandle: @unchecked Sendable {
    private var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    func take() -> OpaquePointer { let value = pointer!; pointer = nil; return value }
    deinit { if let pointer { hyperdr_engine_destroy(pointer) } }
}
