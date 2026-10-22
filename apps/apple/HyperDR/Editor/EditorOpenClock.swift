import Foundation

/// Monotonic opening deadlines. Tests advance this clock without wall time.
@MainActor protocol EditorOpenClock: AnyObject {
    var now: Duration { get }
    func sleep(until deadline: Duration) async throws
}

@MainActor final class SystemEditorOpenClock: EditorOpenClock {
    static let shared = SystemEditorOpenClock()
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now
    var now: Duration { origin.duration(to: clock.now) }
    func sleep(until deadline: Duration) async throws {
        try await clock.sleep(until: origin.advanced(by: deadline))
    }
}

extension EditorServices {
    var openClock: any EditorOpenClock { SystemEditorOpenClock.shared }
}
