import Foundation
import HyperDREngine

/// Composition root for the non-UI service layer. One instance per process.
/// Preview, job and resource services are added by K2-K5.
public final class HyperDRKit: Sendable {
    public let engine: Engine
    public let schema: SettingsSchema
    let capabilities: Capabilities
    public let formats: InputFormats
    public let sessions: SessionStore
    public let previews: PreviewService
    public let jobs: JobRunner
    public let exportTarget: ExportTarget

    private final class CleanupState: @unchecked Sendable {
        let lock = NSLock()
        var started = false
        var generation = 0
        var task: Task<Void, Never>?
        var activeLoops = 0
    }

    private let cleanupInterval: Duration
    private let cleanup: @Sendable () async -> Int
    private let cleanupState = CleanupState()

    public convenience init(configuration: KitConfiguration = .init()) async throws {
        try await self.init(configuration: configuration, cleanupInterval: .seconds(3600))
    }

    internal init(configuration: KitConfiguration, cleanupInterval: Duration,
                  cleanup: (@Sendable () async -> Int)? = nil) async throws {
        let engine = try await Engine(configuration: EngineConfiguration(
            cacheDirectory: configuration.cacheDirectory.appendingPathComponent("decode-cache", isDirectory: true),
            memoryBudgetBytes: 0, heicTileWorkers: 0))
        let schema = try Engine.schema()
        let capabilities = try await engine.capabilities()
        let formats = try InputFormats(schema: schema)
        self.engine = engine
        self.schema = schema
        self.capabilities = capabilities
        self.formats = formats
        let sessions = SessionStore(configuration: configuration, formats: formats)
        self.sessions = sessions
        self.cleanup = cleanup ?? { await sessions.cleanupExpired() }
        self.previews = PreviewService(configuration: configuration, schema: schema,
            capabilities: capabilities, sessions: sessions, engine: engine)
        self.jobs = JobRunner(configuration: configuration, schema: schema,
            capabilities: capabilities, sessions: sessions, engine: engine)
        self.exportTarget = ExportTarget(configuration: configuration, sessions: sessions)
        self.cleanupInterval = cleanupInterval
    }

    /// Run the startup cleanup and keep a single hourly cleanup loop alive.
    /// The App calls this when its editor scene starts; A2 owns the lifecycle.
    public func start() async {
        let token: Int? = cleanupState.lock.withLock {
            guard !cleanupState.started else { return nil }
            cleanupState.started = true
            cleanupState.generation += 1
            return cleanupState.generation
        }
        guard let token else { return }
        _ = await cleanup()
        let cleanup = self.cleanup
        let interval = cleanupInterval
        let state = cleanupState
        let task = Task {
            if Task.isCancelled { return }
            state.lock.withLock { state.activeLoops += 1 }
            defer { state.lock.withLock { state.activeLoops -= 1 } }
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { break }
                _ = await cleanup()
            }
        }
        // A stop() during the startup await invalidated this token; a later
        // start() owns the loop instead, so never overwrite its task.
        let keep = state.lock.withLock {
            guard state.started, state.generation == token else { return false }
            state.task = task
            return true
        }
        if !keep { task.cancel() }
    }

    public func stop() {
        let task = cleanupState.lock.withLock {
            cleanupState.started = false
            cleanupState.generation += 1
            let task = cleanupState.task
            cleanupState.task = nil
            return task
        }
        task?.cancel()
    }

    internal var activeCleanupLoops: Int {
        cleanupState.lock.withLock { cleanupState.activeLoops }
    }

    deinit { stop() }
}
