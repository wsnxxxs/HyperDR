import Foundation
import HyperDREngineCore

/// Native work runs on GCD threads, never on Swift's cooperative executor.
enum EngineExecutor {
    static let queue = DispatchQueue(label: "org.hyperdr.engine", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable (Cancellation) throws -> T) async throws -> T {
        let cancellation = try Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let result = try work(cancellation)
                        try cancellation.check()
                        return result
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// The native token is thread-safe. It cannot be destroyed until the queued work
/// and cancellation handler both relinquish this object.
final class Cancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    private let lock = NSLock()
    private var cancelled = false
    init() throws {
        guard let pointer = hyperdr_cancel_create() else {
            throw HyperDRError(code: "out_of_memory", message: "Unable to allocate cancellation token")
        }
        self.pointer = pointer
    }
    func cancel() {
        lock.withLock { cancelled = true; hyperdr_cancel_request(pointer) }
    }
    func check() throws {
        if lock.withLock({ cancelled }) {
            throw HyperDRError(code: "cancelled", message: "Operation cancelled")
        }
    }
    deinit { hyperdr_cancel_destroy(pointer) }
}
