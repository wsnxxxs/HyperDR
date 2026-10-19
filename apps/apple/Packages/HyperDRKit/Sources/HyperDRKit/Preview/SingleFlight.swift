import Foundation

/// One execution per key. The leader runs the operation in its own task, so a
/// cancelled leader propagates cancellation to the work; followers observe the
/// leader's value or error and are released together.
actor SingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Value, Error>
    }

    private final class Flight: @unchecked Sendable {
        var waiters: [Waiter] = []
    }

    private var flights: [Key: Flight] = [:]

    var inFlight: Int { flights.count }

    /// Read-only scheduling observation for deterministic concurrency tests.
    var waiterCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }

    func run(_ key: Key, operation: @Sendable () async throws -> Value) async throws -> Value {
        if let flight = flights[key] {
            let waiter = UUID()
            let value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    flight.waiters.append(Waiter(id: waiter, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(key: key, id: waiter) }
            }
            if Task.isCancelled { throw CancellationError() }
            return value
        }

        let flight = Flight()
        flights[key] = flight
        do {
            let value = try await operation()
            flights.removeValue(forKey: key)
            for waiter in flight.waiters { waiter.continuation.resume(returning: value) }
            return value
        } catch {
            flights.removeValue(forKey: key)
            for waiter in flight.waiters { waiter.continuation.resume(throwing: error) }
            throw error
        }
    }

    private func cancelWaiter(key: Key, id: UUID) {
        guard let flight = flights[key],
              let index = flight.waiters.firstIndex(where: { $0.id == id }) else { return }
        flight.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
