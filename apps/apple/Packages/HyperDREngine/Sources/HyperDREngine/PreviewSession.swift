import Foundation
import HyperDREngineCore

/// `OpaquePointer` is not `Sendable`, but the native session handle is only
/// used behind `PreviewSession`'s reservation, never shared concurrently.
private struct SessionHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Test-only observation of native releases: a session must close its handle
/// exactly once, whether it is closed explicitly or released by ARC. Counts are
/// per session so tests that run in parallel cannot disturb each other.
final class PreviewCloseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Int] = [:]

    func count(for identifier: UUID) -> Int { lock.withLock { counts[identifier] ?? 0 } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
    fileprivate func record(_ identifier: UUID) {
        lock.withLock { counts[identifier, default: 0] += 1 }
    }
}

/// One active call per session. Concurrent calls fail with `busy`, without
/// queuing in the wrapper. Sessions can outlive the Engine that created them.
public final class PreviewSession: @unchecked Sendable {
    /// Identifies this session in `closeLog`, which is how the tests prove the
    /// native handle is released exactly once.
    let identifier = UUID()
    private var pointer: OpaquePointer?
    private let lock = NSLock()
    private var active = false
    private var closed = false
    init(pointer: OpaquePointer) { self.pointer = pointer }
    deinit {
        // A session nobody closed explicitly still owns its native handle:
        // mark it closed inside the same lock, then hand the handle out once.
        let handle = lock.withLock { () -> OpaquePointer? in
            closed = true
            return takeClosedHandle()
        }
        if let handle { Self.closeNative(handle, identifier) }
    }

    /// Releases the native session now instead of waiting for `deinit`.
    /// Idempotent, and safe to call while a call is still reserved: the handle
    /// is closed as soon as that call returns, so the Swift wrapper never
    /// touches freed memory. Later calls fail with `cancelled`.
    public func close() {
        if let handle = lock.withLock({ () -> OpaquePointer? in
            closed = true
            return takeClosedHandle()
        }) { Self.closeNative(handle, identifier) }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// Counts native releases for the tests; the single hand-out below is what
    /// keeps close/deinit/release to exactly one close per session.
    static let closeLog = PreviewCloseLog()

    private static func closeNative(_ handle: OpaquePointer, _ identifier: UUID) {
        closeLog.record(identifier)
        hyperdr_preview_close(handle)
    }

    /// Caller must hold the lock. Hands the handle out exactly once, and only
    /// when no call is still using it.
    private func takeClosedHandle() -> OpaquePointer? {
        guard closed, !active, let handle = pointer else { return nil }
        pointer = nil
        return handle
    }

    private func reserve() throws {
        try lock.withLock {
            guard !closed else {
                throw HyperDRError(code: "cancelled", message: "Preview session is closed")
            }
            guard !active else { throw HyperDRError(code: "busy", message: "Preview session is busy") }
            active = true
        }
    }
    private func release() {
        if let handle = lock.withLock({ () -> OpaquePointer? in
            active = false
            return takeClosedHandle()
        }) { Self.closeNative(handle, identifier) }
    }

    /// Snapshot of the native handle taken after `reserve()`; the handle cannot
    /// be freed while `active` is set, so this stays valid for the whole call.
    private func handle() throws -> SessionHandle {
        guard let handle = lock.withLock({ pointer }) else {
            throw HyperDRError(code: "cancelled", message: "Preview session is closed")
        }
        return SessionHandle(pointer: handle)
    }

    /// Test-only observation of the reservation. Production callers rely on
    /// `busy`; this lets tests wait until the first call holds the session
    /// instead of guessing at task scheduling.
    var isReserved: Bool { lock.withLock { active } }

    public func renderFrame(_ request: EngineRequest) async throws -> PreviewFrame {
        try reserve()
        defer { release() }
        let session = try handle()
        let trace = PreviewTrace.current ?? PreviewTrace()
        return try await EngineExecutor.run { cancellation in
            let interval = trace.begin("render_frame")
            defer { trace.end("render_frame", interval) }
            var frame = hyperdr_frame()
            var error: UnsafeMutablePointer<hyperdr_error>?
            let status = try encodeJSON(request).withCString {
                hyperdr_preview_render_frame(session.pointer, $0, cancellation.pointer, &frame, &error)
            }
            // Own even partially populated results before checking status.
            let storage = FrameStorage(frame)
            try checkStatus(status, error)
            return try PreviewFrame(storage: storage, trace: trace)
        }
    }
    public func renderPacket(_ request: EngineRequest) async throws -> Data {
        try await buffer(request, model: false)
    }
    public func modelGain(_ request: EngineRequest) async throws -> Data {
        try await buffer(request, model: true)
    }
    private func buffer(_ request: EngineRequest, model: Bool) async throws -> Data {
        try reserve()
        defer { release() }
        let session = try handle()
        return try await EngineExecutor.run { cancellation in
            var buffer = hyperdr_buffer()
            var error: UnsafeMutablePointer<hyperdr_error>?
            defer { hyperdr_buffer_free(&buffer) }
            let status = try encodeJSON(request).withCString {
                if model { return hyperdr_model_gain(session.pointer, $0, cancellation.pointer, &buffer, &error) }
                return hyperdr_preview_render(session.pointer, $0, cancellation.pointer, &buffer, &error)
            }
            try checkStatus(status, error)
            guard let data = buffer.data else {
                throw HyperDRError(code: "internal_error", message: "Missing engine buffer")
            }
            return Data(bytes: data, count: buffer.size)
        }
    }
}
