import Observation

/// What `Observations` (macOS 26) does, for macOS 15 to 25: on the main actor
/// it yields the value `read` returns, first at once and then again each time
/// something `read` touched has changed (changes that land before the
/// consumer is back are coalesced into one value, as `Observations` does).
///
/// Built from `withObservationTracking`, which fires once per registration, so
/// every wake-up reads again and registers again. The stream ends when the
/// consuming task is cancelled or the stream is dropped; the producing task is
/// cancelled with it and finishes the stream, so nothing is left waiting.
/// Call sites keep their own `Task.checkCancellation()`: cancellation ends the
/// loop here exactly as it does with `Observations`.
enum LegacyObservations {
    @MainActor
    static func values<Value: Sendable>(
        _ read: @escaping @MainActor () -> Value
    ) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (changes, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let producer = Task { @MainActor in
                defer {
                    signal.finish()
                    continuation.finish()
                }
                var iterator = changes.makeAsyncIterator()
                while !Task.isCancelled {
                    let value = withObservationTracking(read) { signal.yield() }
                    continuation.yield(value)
                    // nil: the producer was cancelled while waiting.
                    guard await iterator.next() != nil else { return }
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
