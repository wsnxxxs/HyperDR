import Foundation

/// FIFO async mutex. PreviewService keeps one per session so the submit
/// in-flight render and direct reference/detail renders never enter the same
/// engine PreviewSession together (the engine would answer `busy`).
actor SessionGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
