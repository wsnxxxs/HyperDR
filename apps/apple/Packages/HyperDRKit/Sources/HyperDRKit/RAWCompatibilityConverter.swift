import CryptoKit
import Foundation
import HyperDREngine
import HyperDRRender

/// Engine-backed RAW conversion with a content/revision keyed disk cache.
/// The cache lives below SessionStore's decode-cache, so its existing age/byte
/// trimming also reclaims DNGs and embedded JPEGs.
public actor RAWCompatibilityConverter: RAWCompatibilityConverting {
    public nonisolated let converterID: String

    typealias Operation = @Sendable (_ source: URL, _ output: URL) async throws -> Int32?

    private struct CacheResult: Sendable {
        let url: URL
        let usedCache: Bool
        let orientation: Int32?
    }
    private struct Flight: Sendable {
        let id: UUID
        let task: Task<CacheResult, any Error>
    }

    private let root: URL
    private let convertOperation: Operation
    private let extractOperation: Operation
    private let fileManager = FileManager.default
    private var flights: [String: Flight] = [:]
    private var waiters: [String: Set<UUID>] = [:]

    /// The production initializer is added beside HyperDREngine's ABI wrapper.
    /// Tests supply the same two asynchronous operations directly.
    init(root: URL, converterID: String,
         convert: @escaping Operation, extract: @escaping Operation) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.converterID = converterID
        self.convertOperation = convert
        self.extractOperation = extract
    }

    public func convertDNG(from source: URL) async throws -> RAWConvertedDNG {
        try Task.checkCancellation()
        let result = try await cached(source, kind: "dng", operation: convertOperation)
        return RAWConvertedDNG(url: result.url, converterID: converterID, usedCache: result.usedCache)
    }

    public func extractEmbeddedPreview(from source: URL) async throws -> RAWEmbeddedPreview {
        try Task.checkCancellation()
        let result = try await cached(source, kind: "jpg", operation: extractOperation)
        return RAWEmbeddedPreview(url: result.url, usedCache: result.usedCache, orientation: result.orientation)
    }

    private func cached(_ source: URL, kind: String, operation: @escaping Operation) async throws -> CacheResult {
        let key = try Self.cacheKey(source, converterID: converterID, kind: kind)
        let output = root.appendingPathComponent(key + "." + kind)
        if let cached = cachedFile(output, kind: kind) {
            try Task.checkCancellation()
            return cached
        }
        if let existing = flights[key] {
            return try await awaitFlight(key, flight: existing)
        }
        let id = UUID()
        let task = Task.detached { [root] in
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let temporary = root.appendingPathComponent(key + "." + UUID().uuidString + "." + kind)
                do {
                    let orientation = try await operation(source, temporary)
                    let raced = try Self.publish(temporary, to: output, kind: kind, orientation: orientation)
                    return CacheResult(url: output, usedCache: raced, orientation: orientation)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    try? FileManager.default.removeItem(at: temporary.appendingPathExtension("orientation"))
                    throw Self.mapped(error)
                }
            } catch {
                throw Self.mapped(error)
            }
        }
        let flight = Flight(id: id, task: task)
        flights[key] = flight
        Task { [weak self] in
            _ = await task.result
            await self?.finishFlight(key, id: id)
        }
        return try await awaitFlight(key, flight: flight)
    }

    private func finishFlight(_ key: String, id: UUID) {
        guard flights[key]?.id == id else { return }
        flights[key] = nil
        waiters[key] = nil
    }

    private func cachedFile(_ url: URL, kind: String) -> CacheResult? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
            return nil
        }
        let orientation: Int32?
        if kind == "jpg" {
            let metadata = url.appendingPathExtension("orientation")
            guard let text = try? String(contentsOf: metadata, encoding: .utf8),
                  let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...8).contains(value) else {
                try? fileManager.removeItem(at: url)
                try? fileManager.removeItem(at: metadata)
                return nil
            }
            orientation = value
        } else {
            orientation = nil
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return CacheResult(url: url, usedCache: true, orientation: orientation)
    }

    /// Publish beside the cache file, so rename is atomic. Another converter
    /// instance may win the same key; its complete file is just as reusable.
    private static func publish(_ temporary: URL, to output: URL, kind: String,
                                orientation: Int32?) throws -> Bool {
        let raced: Bool
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
            raced = false
        } catch {
            guard FileManager.default.fileExists(atPath: output.path) else { throw error }
            try? FileManager.default.removeItem(at: temporary)
            raced = true
        }
        if kind == "jpg" {
            let metadata = output.appendingPathExtension("orientation")
            let temporaryMetadata = temporary.appendingPathExtension("orientation")
            try Data(String(orientation ?? 1).utf8).write(to: temporaryMetadata, options: .atomic)
            do {
                try FileManager.default.moveItem(at: temporaryMetadata, to: metadata)
            } catch {
                if !FileManager.default.fileExists(atPath: metadata.path) { throw error }
                try? FileManager.default.removeItem(at: temporaryMetadata)
            }
        }
        return raced
    }

    private func awaitFlight(_ key: String, flight: Flight) async throws -> CacheResult {
        let waiter = UUID()
        waiters[key, default: []].insert(waiter)
        defer { waiters[key]?.remove(waiter) }
        let result = try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { await self.cancelWaiter(key, waiter: waiter, flight: flight.id) }
        }
        try Task.checkCancellation()
        return result
    }

    private func cancelWaiter(_ key: String, waiter: UUID, flight id: UUID) {
        guard waiters[key]?.contains(waiter) == true else { return }
        waiters[key]?.remove(waiter)
        if waiters[key]?.isEmpty == true, flights[key]?.id == id {
            flights[key]?.task.cancel()
        }
    }

    private static func cacheKey(_ source: URL, converterID: String, kind: String) throws -> String {
        var source = source
        source.removeAllCachedResourceValues()
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let modified = values.contentModificationDate?.timeIntervalSince1970.bitPattern ?? 0
        let identity = [source.standardizedFileURL.path, String(values.fileSize ?? -1),
                        String(modified, radix: 16), converterID, kind].joined(separator: "\0")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Render owns the public error vocabulary; Kit translates the engine's
    /// structured camera failure without allowing implementation detail text
    /// (which could contain a path) into the user-facing detail.
    private static func mapped(_ error: any Error) -> any Error {
        guard let error = error as? HyperDRError else { return error }
        if error.code == "no_preview" { return RAWCompatibilityError.noPreview }
        guard error.code == "raw_unsupported" else { return error }
        var model: String?
        if case .object(let fields) = error.detail,
           case .string(let value) = fields["model"], !value.isEmpty {
            model = value
        }
        return RenderError.rawUnsupported(camera: model)
    }
}
