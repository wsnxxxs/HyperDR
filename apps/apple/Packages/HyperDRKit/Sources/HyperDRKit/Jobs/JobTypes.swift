import CryptoKit
import Foundation
import HyperDREngine

public enum JobActivity: Sendable, Equatable {
    case idle, preparing, running(JobID), committing(JobID)
}

/// Resolved request identity, independent of temporary input/output paths.
public struct ExportKey: Sendable, Codable, Equatable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    init(request: EngineRequest, frame: ExportFrameRecord?) throws {
        var command = request.command
        for key in ["input", "output", "report"] { command.removeValue(forKey: key) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let frameValue: JSONValue = try frame.map {
            try JSONDecoder().decode(JSONValue.self, from: encoder.encode($0))
        } ?? .null
        rawValue = String(decoding: try encoder.encode([
            "settings": JSONValue.object(request.settings), "command": .object(command), "frame": frameValue
        ]), as: UTF8.self)
    }
}

/// Durable frame identity: no temporary paths or PNG payload in history.
public struct ExportFrameRecord: Sendable, Codable, Equatable {
    public let spec: [String: JSONValue]
    public let overlaySHA256: String?
    public init(_ frame: ExportFrame) throws {
        guard frame.spec["overlay"] == nil else {
            throw HyperDRError(code: "invalid_options", message: "Overlay must be supplied as PNG data")
        }
        spec = frame.spec
        overlaySHA256 = frame.overlayPNG.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}

public struct SavedMark: Sendable, Codable, Equatable {
    public let fileName: String
    /// Last directory display name at save time, never a path.
    /// Missing in older records: consumers show their localized unknown label.
    public let folderDisplayName: String?
    public let savedAt: Date
    public init(fileName: String, folderDisplayName: String?, savedAt: Date = Date()) {
        self.fileName = fileName; self.folderDisplayName = folderDisplayName; self.savedAt = savedAt
    }
}

public struct JobID: Sendable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
public struct JobTicket: Sendable {
    public let job: JobID
    public let export: ExportID
    public let argv: [String]
}
public struct ExportFrame: Sendable, Hashable, Codable {
    public var spec: [String: JSONValue]
    public var overlayPNG: Data?
    public init(spec: [String: JSONValue], overlayPNG: Data? = nil) {
        self.spec = spec; self.overlayPNG = overlayPNG
    }
}
public struct JobSummary: Sendable {
    public let id: JobID
    public let session: SessionID
    public let done: Bool
    public let cancelled: Bool
    public let timedOut: Bool
    public let failure: HyperDRError?
    public let result: ExportRecord?
    /// Non-nil only after automatic delivery to a preselected save-panel URL.
    public let saved: SavedExport?
}
public struct JobSnapshot: Sendable {
    public let summary: JobSummary
    public let text: String
    public let offset: Int
    public let logStart: Int
    public let truncated: Bool
}
public enum JobEvent: Sendable {
    case publishing, saving
    case progress(ConvertEvent)
    case log(String)
    case finished(JobSummary)
}

/// Subscription is synchronous; callbacks enter one FIFO stream, never one
/// unstructured task per callback. Terminal delivery closes all subscribers.
final class JobEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [JobID: [UUID: AsyncStream<JobEvent>.Continuation]] = [:]
    private var terminal: [JobID: JobSummary] = [:]
    private var active: JobID?
    private var history: [JobEvent] = []

    func begin(_ id: JobID) { lock.withLock { active = id; history = [] } }

    func stream(_ id: JobID) -> AsyncStream<JobEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: JobEvent.self, bufferingPolicy: .bufferingNewest(256))
        let token = UUID()
        lock.withLock {
            if let result = terminal[id] {
                continuation.yield(.finished(result)); continuation.finish()
            } else if active == id {
                // start() can return after the first engine callback. Replay a
                // bounded prefix so subscribing immediately cannot miss decode.
                for event in history { continuation.yield(event) }
                streams[id, default: [:]][token] = continuation
            }
            else { continuation.finish() }
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.streams[id]?.removeValue(forKey: token) }
        }
        return stream
    }
    func emit(_ event: JobEvent, id: JobID) {
        let subscribers = lock.withLock {
            let subscribers = Array(streams[id]?.values ?? [:].values)
            if case .finished(let result) = event {
                terminal[id] = result
                streams.removeValue(forKey: id)
                history = []
            } else {
                history.append(event)
                if history.count > 256 { history.removeFirst(history.count - 256) }
            }
            return subscribers
        }
        for stream in subscribers { stream.yield(event) }
        if case .finished = event { for stream in subscribers { stream.finish() } }
    }
    func forget(_ id: JobID) {
        let subscribers = lock.withLock {
            terminal.removeValue(forKey: id)
            if active == id { active = nil; history = [] }
            return Array(streams.removeValue(forKey: id)?.values ?? [:].values)
        }
        for stream in subscribers { stream.finish() }
    }
}
