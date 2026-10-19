import Foundation
import Synchronization

/// A latched gate with synchronous release for reliable defer cleanup. Unlike
/// a sleep, it never succeeds naturally while another task is awaiting a turn.
final class TestStepGate: Sendable {
    private struct State {
        var entered = false
        var cancelled = false
        var released = false
        var continuations: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    var entered: Bool { state.withLock { $0.entered } }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func wait(releaseOnCancel: Bool = false) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let released = state.withLock { state in
                    state.entered = true
                    if state.released { return true }
                    state.continuations.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
        } onCancel: {
            self.state.withLock { $0.cancelled = true }
            if releaseOnCancel { self.release() }
        }
    }

    func release() {
        let continuations = state.withLock { state in
            state.released = true
            defer { state.continuations = [] }
            return state.continuations
        }
        for continuation in continuations { continuation.resume() }
    }
}

