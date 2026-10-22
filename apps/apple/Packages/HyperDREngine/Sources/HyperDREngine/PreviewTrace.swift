import Foundation
import os

/// One preview request, carried unchanged through the service, engine and
/// canvas. No paths, photo names or editing values are recorded. Intervals are
/// visible in Instruments; opt-in text records also survive `log show`.
public final class PreviewTrace: @unchecked Sendable {
    @TaskLocal public static var current: PreviewTrace?
    private static let signposter = OSSignposter(subsystem: "com.hyperdr.HyperDR", category: "PreviewTiming")
    private static let logger = Logger(subsystem: "com.hyperdr.HyperDR", category: "PreviewTiming")
    public static let recordsEnabled = ProcessInfo.processInfo.environment["HDR_PREVIEW_TIMINGS"] == "1"
        || UserDefaults.standard.bool(forKey: "HDRPreviewTimings")
    private let recording: Bool
    private var onRecord: (@Sendable (String, String) -> Void)? = nil
    public let token = UUID().uuidString
    private let id = signposter.makeSignpostID()
    private let lock = NSLock()
    private var presented = false
    private let requestInterval: OSSignpostIntervalState

    public init(recording: Bool = PreviewTrace.recordsEnabled) {
        self.recording = recording
        requestInterval = Self.signposter.beginInterval("RequestToPresent", id: id)
        record("request", "begin")
    }
    /// Deterministic event assertions without reading asynchronous system logs.
    @_spi(Testing) public convenience init(onRecord: @escaping @Sendable (String, String) -> Void) {
        self.init(recording: false)
        self.onRecord = onRecord
    }
    deinit {
        if !presented {
            record("request", "dropped")
            Self.signposter.endInterval("RequestToPresent", requestInterval)
        }
    }
    public func begin(_ stage: StaticString) -> OSSignpostIntervalState {
        record(String(describing: stage), "begin")
        return Self.signposter.beginInterval(stage, id: id)
    }
    public func end(_ stage: StaticString, _ interval: OSSignpostIntervalState) {
        Self.signposter.endInterval(stage, interval)
        record(String(describing: stage), "end")
    }
    public func record(_ stage: String, _ event: String, nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        onRecord?(stage, event)
        guard recording else { return }
        Self.logger.info("A3 trace=\(self.token, privacy: .public) stage=\(stage, privacy: .public) event=\(event, privacy: .public) ns=\(nanoseconds, privacy: .public)")
    }
    public func gpuInterval(start: UInt64, end: UInt64) {
        record("pass1_gpu", "begin", nanoseconds: start)
        record("pass1_gpu", "end", nanoseconds: end)
        Self.signposter.emitEvent("Pass1GPU", id: id, "duration_ns=\(end - start)")
    }
    /// Metal timestamps are seconds on the host clock. Only a real presented
    /// callback completes end-to-end latency; commit/GPU completion do not.
    public var hasPresented: Bool { lock.withLock { presented } }
    public func didPresent(at time: CFTimeInterval) {
        guard time > 0, time.isFinite else { return }
        let first = lock.withLock { if presented { return false }; presented = true; return true }
        guard first else { return }
        record("presented", "point", nanoseconds: UInt64(time * 1e9))
        Self.signposter.endInterval("RequestToPresent", requestInterval)
    }
}
