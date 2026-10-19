import Foundation
import HyperDREngine

/// A bounded asynchronous semaphore. RAW previews and model-gain share one
/// instance so their RAW development working sets cannot overlap accidentally.
actor RawDecodeGate {
    struct Ticket: Sendable {
        private let gate: RawDecodeGate
        private let id: UUID

        init(gate: RawDecodeGate, id: UUID) {
            self.gate = gate
            self.id = id
        }

        func release() async { await gate.release(id) }
    }

    private let slots: Int
    private var available: Int
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var outstanding: Set<UUID> = []

    init(slots: Int) {
        self.slots = max(1, slots)
        available = max(1, slots)
    }

    func acquire(timeout: Duration) async throws -> Ticket {
        if available > 0 {
            available -= 1
            let id = UUID()
            outstanding.insert(id)
            return Ticket(gate: self, id: id)
        }

        let id = UUID()
        do {
            try await withTaskCancellationHandler(operation: {
                try await self.enqueue(id: id, timeout: timeout)
            }, onCancel: {
                Task { await self.cancel(id) }
            })
            try Task.checkCancellation()
        } catch {
            release(id)
            throw error
        }
        return Ticket(gate: self, id: id)
    }

    private func enqueue(id: UUID, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters[id] = continuation
            order.append(id)
            timers[id] = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.timeout(id)
            }
        }
    }

    func release(_ id: UUID) {
        guard outstanding.remove(id) != nil else { return }
        if let next = order.first, let continuation = waiters.removeValue(forKey: next) {
            order.removeFirst()
            timers.removeValue(forKey: next)?.cancel()
            outstanding.insert(next)
            continuation.resume()
        } else {
            available = min(slots, available + 1)
        }
    }

    private func timeout(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        timers.removeValue(forKey: id)
        continuation.resume(throwing: HyperDRError(code: "raw_budget",
            message: "RAW decode is already in use"))
    }

    private func cancel(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        timers.removeValue(forKey: id)
        continuation.resume(throwing: CancellationError())
    }
}
