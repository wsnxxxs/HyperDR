import Foundation
import HyperDREngineCore

/// One active call per session. Concurrent calls fail with `busy`, without
/// queuing in the wrapper. Sessions can outlive the Engine that created them.
public final class PreviewSession: @unchecked Sendable {
    private let pointer: OpaquePointer
    private let lock = NSLock()
    private var active = false
    init(pointer: OpaquePointer) { self.pointer = pointer }
    deinit { hyperdr_preview_close(pointer) }

    private func reserve() throws {
        try lock.withLock {
            guard !active else { throw HyperDRError(code: "busy", message: "Preview session is busy") }
            active = true
        }
    }
    private func release() { lock.withLock { active = false } }

    /// Test-only observation of the reservation. Production callers rely on
    /// `busy`; this lets tests wait until the first call holds the session
    /// instead of guessing at task scheduling.
    var isReserved: Bool { lock.withLock { active } }

    public func renderFrame(_ request: EngineRequest) async throws -> PreviewFrame {
        try reserve()
        defer { release() }
        return try await EngineExecutor.run { cancellation in
            var frame = hyperdr_frame()
            var error: UnsafeMutablePointer<hyperdr_error>?
            let status = try encodeJSON(request).withCString {
                hyperdr_preview_render_frame(self.pointer, $0, cancellation.pointer, &frame, &error)
            }
            // Own even partially populated results before checking status.
            let storage = FrameStorage(frame)
            try checkStatus(status, error)
            return try PreviewFrame(storage: storage)
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
        return try await EngineExecutor.run { cancellation in
            var buffer = hyperdr_buffer()
            var error: UnsafeMutablePointer<hyperdr_error>?
            defer { hyperdr_buffer_free(&buffer) }
            let status = try encodeJSON(request).withCString {
                if model { return hyperdr_model_gain(self.pointer, $0, cancellation.pointer, &buffer, &error) }
                return hyperdr_preview_render(self.pointer, $0, cancellation.pointer, &buffer, &error)
            }
            try checkStatus(status, error)
            guard let data = buffer.data else {
                throw HyperDRError(code: "internal_error", message: "Missing engine buffer")
            }
            return Data(bytes: data, count: buffer.size)
        }
    }
}
