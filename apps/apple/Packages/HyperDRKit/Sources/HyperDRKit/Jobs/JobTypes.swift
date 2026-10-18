import Foundation
import HyperDREngine

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
}
public struct JobSnapshot: Sendable {
    public let summary: JobSummary
    public let text: String
    public let offset: Int
    public let logStart: Int
    public let truncated: Bool
}
public enum JobEvent: Sendable {
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
