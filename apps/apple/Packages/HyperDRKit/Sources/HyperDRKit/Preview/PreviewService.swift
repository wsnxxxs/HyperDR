import Foundation
import HyperDREngine

/// The subset of an engine preview session PreviewService needs. Keeping it a
/// protocol lets tests provide controllable delays and observe cancellation
/// without changing the production reservation semantics.
protocol PreviewRenderSession: Sendable {
    func renderFrame(_ request: EngineRequest) async throws -> PreviewFrame
    func close() async
}

extension PreviewSession: PreviewRenderSession {}

struct PreviewCacheKey: Hashable, Sendable {
    let session: SessionID
    let sourceDigest: String
    let buildFingerprint: String
    let requestJSON: Data

    init(session: PhotoSession, request: EngineRequest, buildFingerprint: String) throws {
        self.session = session.id
        self.sourceDigest = session.sha256
        self.buildFingerprint = buildFingerprint
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { self.requestJSON = try encoder.encode(request) }
        catch {
            throw HyperDRError(code: "internal_error",
                message: "Unable to encode the normalized preview request: \(error)")
        }
    }
}

private final class PreviewEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [SessionID: [UUID: AsyncStream<PreviewEvent>.Continuation]] = [:]

    func stream(for id: SessionID) -> AsyncStream<PreviewEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PreviewEvent.self,
            bufferingPolicy: .bufferingNewest(64))
        let token = UUID()
        lock.withLock { continuations[id, default: [:]][token] = continuation }
        continuation.onTermination = { [weak self] _ in self?.remove(id, token) }
        return stream
    }

    func emit(_ event: PreviewEvent, for id: SessionID) {
        let values = lock.withLock { continuations[id].map { Array($0.values) } ?? [] }
        for continuation in values { continuation.yield(event) }
    }

    func finish(_ id: SessionID) {
        let values = lock.withLock { continuations.removeValue(forKey: id) }
            .map { Array($0.values) } ?? []
        for continuation in values { continuation.finish() }
    }

    private func remove(_ id: SessionID, _ token: UUID) {
        lock.withLock { _ = continuations[id]?.removeValue(forKey: token) }
    }
}

public actor PreviewService {
    private struct Prepared: Sendable {
        let request: PreviewRequest
        let engineRequest: EngineRequest
        let key: PreviewCacheKey
        let submittedAt: ContinuousClock.Instant
    }

    private struct EngineRenderResult: Sendable {
        let frame: PreviewFrame
        let timings: PreviewTimings
    }

    /// Merged direct renders are scoped to one generation of one session: a
    /// replacement attach must never join a flight that is being cancelled on
    /// behalf of the photo it replaced.
    private struct FlightKey: Hashable, Sendable {
        let generation: UInt64
        let cacheKey: PreviewCacheKey
    }

    private final class SessionState: @unchecked Sendable {
        /// Lifetime of one subscription. An explicit detach ends it; replacing
        /// the engine session because the source file changed does not.
        let epoch: UInt64
        /// Engine session identity, bumped whenever the renderer is replaced.
        let generation: UInt64
        let photo: PhotoSession
        let renderer: any PreviewRenderSession
        let gate = SessionGate()
        var detached = false
        var inFlight: Task<Void, Never>?
        var inFlightToken: UUID?
        var inFlightPrepared: Prepared?
        var pending: Prepared?
        /// Direct renders (reference frame, detail region, tests) run in tasks
        /// the service owns so `detach` can cancel them instead of waiting for
        /// the engine call to finish on its own.
        var directWork: [UUID: Task<EngineRenderResult, Error>] = [:]

        init(epoch: UInt64, generation: UInt64, photo: PhotoSession,
             renderer: any PreviewRenderSession) {
            self.epoch = epoch
            self.generation = generation
            self.photo = photo
            self.renderer = renderer
        }
    }

    private let resolver: OptionResolver
    private let buildFingerprint: String
    private let previewTimeout: Duration
    private let rawDecodeTimeout: Duration
    private let sessionProvider: @Sendable (SessionID) async throws -> PhotoSession
    private let rendererFactory: @Sendable (PhotoSession) throws -> any PreviewRenderSession
    private let cache: PreviewCache<PreviewCacheKey, PreviewFrame>
    private let singleFlight = SingleFlight<FlightKey, EngineRenderResult>()
    nonisolated let rawGate: RawDecodeGate
    private let eventHub = PreviewEventHub()
    private var states: [SessionID: SessionState] = [:]
    /// Ordering tickets for `submit` and the generation counter for engine
    /// sessions. Both are allocated before any `await` so a slow session lookup
    /// cannot let an older request win over a newer one.
    private var submitCounter: UInt64 = 0
    private var latestSubmit: [SessionID: UInt64] = [:]
    private var generationCounter: UInt64 = 0
    private var epochCounter: UInt64 = 0
    /// Explicit detach count per session: the only thing that ends a
    /// subscription and makes an in-progress request stale.
    private var detachEpochs: [SessionID: UInt64] = [:]

    /// Production wiring: session lookup from disk and one lazy engine preview
    /// session per attached photo.
    public init(configuration: KitConfiguration, schema: SettingsSchema,
                capabilities: Capabilities, sessions: SessionStore, engine: Engine) {
        let models = Self.modelAvailability(capabilities)
        self.init(schema: schema, buildFingerprint: capabilities.buildFingerprint,
            knownModels: models.models, defaultModelID: models.defaultID,
            modelsAvailable: models.ready,
            previewMaxEdge: configuration.previewMaxEdge,
            previewTimeout: configuration.previewTimeout,
            rawDecodeSlots: configuration.rawDecodeSlots, rawDecodeTimeout: .seconds(3),
            cacheEntries: configuration.previewCacheEntries,
            cacheBytes: configuration.previewCacheBytes,
            sessionProvider: { id in try await sessions.session(id) },
            rendererFactory: { photo in
                try engine.openPreview(source: photo.sourceURL, sha256: photo.sha256)
            })
    }

    internal init(schema: SettingsSchema, buildFingerprint: String,
                  knownModels: [String: Bool], defaultModelID: String = "research-cnn-v1",
                  modelsAvailable: Bool = true,
                  previewMaxEdge: Int,
                  previewTimeout: Duration, rawDecodeSlots: Int, rawDecodeTimeout: Duration,
                  cacheEntries: Int, cacheBytes: Int,
                  sessionProvider: @escaping @Sendable (SessionID) async throws -> PhotoSession,
                  rendererFactory: @escaping @Sendable (PhotoSession) throws -> any PreviewRenderSession) {
        self.resolver = OptionResolver(schema: schema, knownModels: knownModels,
            modelsAvailable: modelsAvailable,
            maxEdgeCeiling: previewMaxEdge, defaultModelID: defaultModelID)
        self.buildFingerprint = buildFingerprint
        self.previewTimeout = previewTimeout
        self.rawDecodeTimeout = rawDecodeTimeout
        self.sessionProvider = sessionProvider
        self.rendererFactory = rendererFactory
        self.cache = PreviewCache(entries: cacheEntries, bytes: cacheBytes)
        self.rawGate = RawDecodeGate(slots: rawDecodeSlots)
    }

    // MARK: - Lifecycle and events

    public func attach(_ session: PhotoSession) async throws {
        while true {
            if let existing = states[session.id] {
                if !existing.detached, existing.photo.sha256 == session.sha256,
                   existing.photo.sourceURL == session.sourceURL {
                    return
                }
                await detach(session.id)
                continue
            }
            let renderer = try rendererFactory(session)
            generationCounter += 1
            epochCounter += 1
            // rendererFactory is synchronous, so no other actor message can
            // install a second engine session between this check and the store.
            states[session.id] = SessionState(epoch: epochCounter,
                generation: generationCounter, photo: session, renderer: renderer)
            return
        }
    }

    public func detach(_ id: SessionID) async {
        detachEpochs[id, default: 0] += 1
        guard let state = states.removeValue(forKey: id) else { return }
        state.detached = true
        if let old = state.inFlightPrepared {
            eventHub.emit(.superseded(old.request), for: id)
        }
        if let pending = state.pending {
            eventHub.emit(.superseded(pending.request), for: id)
        }
        state.inFlight?.cancel()
        state.inFlight = nil
        state.pending = nil
        state.inFlightToken = nil
        state.inFlightPrepared = nil
        for work in state.directWork.values { work.cancel() }
        state.directWork.removeAll()
        // Finish old subscribers before any concurrent attach can install a
        // replacement state for the same id.
        eventHub.finish(id)
        // Wait for the cancelled calls to leave the engine session, and keep the
        // gate while closing so queued direct renders cannot enter it.
        await state.gate.acquire()
        await state.renderer.close()
        await state.gate.release()
        // Frames of the same photo stay valid when the photo was re-attached
        // before this teardown finished (same digest, same build, same
        // request), so only clean up when no state took over, and only for the
        // digest that went away.
        guard states[id] == nil else { return }
        let digest = state.photo.sha256
        await cache.removeAll(where: { $0.session == id && $0.sourceDigest == digest })
    }

    public nonisolated func events(for id: SessionID) -> AsyncStream<PreviewEvent> {
        eventHub.stream(for: id)
    }

    // MARK: - Latest-wins submission

    public func submit(_ request: PreviewRequest) async {
        let id = request.session
        // The ticket is allocated before the first await. Everything this call
        // publishes afterwards is dropped (as superseded) when a later submit
        // for the same session already exists, so a slow session lookup cannot
        // let an older request overwrite a newer frame.
        let order = allocateSubmitOrder(id)
        // Captured before any await: an explicit detach during the session
        // lookup makes this request stale, and a source refresh does not.
        let entryDetachEpoch = detachEpochs[id] ?? 0
        let state: SessionState
        do { state = try await attachedState(id, detachEpoch: entryDetachEpoch) }
        catch {
            if isLatestSubmit(order, id), !isStaleDetach(entryDetachEpoch, id) {
                eventHub.emit(.failed(request, asHyperDRError(error)), for: id)
            } else {
                eventHub.emit(.superseded(request), for: id)
            }
            return
        }
        guard isLatestSubmit(order, id) else {
            eventHub.emit(.superseded(request), for: id)
            return
        }
        let prepared: Prepared
        do { prepared = try prepare(request, state: state) }
        catch {
            if isLatestSubmit(order, id) {
                eventHub.emit(.failed(request, asHyperDRError(error)), for: id)
            } else {
                eventHub.emit(.superseded(request), for: id)
            }
            return
        }

        if let frame = await cache.get(prepared.key) {
            guard isLatestSubmit(order, id), states[id] === state, !state.detached else {
                // Either a newer submit took over or the session went away
                // while the cache lookup was awaiting. Publish a terminal event
                // anyway: subscribers drive their busy state from it.
                eventHub.emit(.superseded(request), for: id)
                return
            }
            if let inFlight = state.inFlight, let old = state.inFlightPrepared {
                inFlight.cancel()
                eventHub.emit(.superseded(old.request), for: id)
                state.inFlight = nil
                state.inFlightToken = nil
                state.inFlightPrepared = nil
            }
            if let pending = state.pending {
                eventHub.emit(.superseded(pending.request), for: id)
                state.pending = nil
            }
            eventHub.emit(.started(request), for: id)
            eventHub.emit(.finished(PreviewResult(request: request, frame: frame,
                fromCache: true, timings: PreviewTimings())), for: id)
            return
        }

        guard isLatestSubmit(order, id), states[id] === state, !state.detached else {
            eventHub.emit(.superseded(request), for: id)
            return
        }
        // The newest request may land back on the value that is already
        // rendering (A → B → A). Reuse that render instead of starting a third
        // one, but discard the different value that was queued behind it.
        if let running = state.inFlightPrepared, running.key == prepared.key {
            if let pending = state.pending {
                eventHub.emit(.superseded(pending.request), for: id)
                state.pending = nil
            }
            if running.request != request {
                eventHub.emit(.superseded(running.request), for: id)
                eventHub.emit(.started(request), for: id)
                state.inFlightPrepared = prepared
            }
            return
        }
        if let pending = state.pending, pending.key == prepared.key {
            if pending.request != request {
                eventHub.emit(.superseded(pending.request), for: id)
                state.pending = prepared
            }
            return
        }

        if state.inFlight != nil {
            if let pending = state.pending {
                eventHub.emit(.superseded(pending.request), for: id)
            }
            state.pending = prepared
            return
        }
        start(prepared, state: state)
    }

    // MARK: - Direct render / SingleFlight

    public func render(_ request: PreviewRequest) async throws -> PreviewResult {
        let state = try await attachedState(request.session,
            detachEpoch: detachEpochs[request.session] ?? 0)
        let prepared = try prepare(request, state: state)
        if let frame = await cache.get(prepared.key) {
            guard states[request.session] === state, !state.detached else {
                throw HyperDRError(code: "cancelled", message: "Preview session was detached")
            }
            return PreviewResult(request: request, frame: frame, fromCache: true,
                timings: PreviewTimings())
        }
        let flightKey = FlightKey(generation: state.generation, cacheKey: prepared.key)
        // A merged flight reports its leader's cancellation to every waiter. A
        // caller that is still alive retries once and becomes the new leader, so
        // someone else's cancellation never surfaces as this caller's result.
        var attempt = 0
        var outcome: EngineRenderResult?
        while outcome == nil {
            attempt += 1
            do {
                outcome = try await singleFlight.run(flightKey) {
                    try await self.performDirectRender(prepared, state: state)
                }
            } catch {
                let cancellation = error is CancellationError
                    || (error as? HyperDRError)?.code == "cancelled"
                guard cancellation, !Task.isCancelled, attempt < 2 else {
                    if let error = error as? HyperDRError { throw error }
                    throw HyperDRError(code: "cancelled", message: "Preview cancelled")
                }
                if let frame = await cache.get(prepared.key) {
                    return PreviewResult(request: request, frame: frame, fromCache: true,
                        timings: PreviewTimings())
                }
            }
        }
        guard let result = outcome, states[request.session] === state, !state.detached else {
            throw HyperDRError(code: "cancelled", message: "Preview session was detached")
        }
        return PreviewResult(request: request, frame: result.frame, fromCache: false,
            timings: result.timings)
    }

    // MARK: - Internals

    private func attachedState(_ id: SessionID, detachEpoch: UInt64) async throws -> SessionState {
        // Refresh the photo first: the store re-hashes a replaced source, and a
        // changed digest has to swap the engine session instead of serving
        // frames cached for the file that used to be there.
        let photo = try await sessionProvider(id)
        guard photo.id == id else {
            // The provider answered for another session. Keep the state that is
            // already installed rather than swapping in a different photo.
            if let state = states[id], !state.detached { return state }
            throw HyperDRError(code: "internal_error",
                message: "Session provider returned a different session")
        }
        guard !isStaleDetach(detachEpoch, id) else {
            // The photo was closed while this request was resolving. Never
            // install an engine session for a request nobody is waiting for.
            throw HyperDRError(code: "cancelled", message: "Preview session was detached")
        }
        if let state = states[id], !state.detached,
           state.photo.sha256 == photo.sha256, state.photo.sourceURL == photo.sourceURL {
            return state
        }
        if let state = states[id], !state.detached {
            return try await replaceRenderer(state, with: photo)
        }
        let renderer = try rendererFactory(photo)
        generationCounter += 1
        epochCounter += 1
        let state = SessionState(epoch: epochCounter, generation: generationCounter,
            photo: photo, renderer: renderer)
        states[id] = state
        return state
    }

    /// Swaps the engine session because the source file changed. The session's
    /// subscription survives: the events hub stays open and the newest request
    /// continues on the new renderer.
    private func replaceRenderer(_ state: SessionState,
                                 with photo: PhotoSession) async throws -> SessionState {
        let id = photo.id
        state.detached = true
        state.inFlight?.cancel()
        state.inFlight = nil
        state.pending = nil
        state.inFlightToken = nil
        state.inFlightPrepared = nil
        for work in state.directWork.values { work.cancel() }
        state.directWork.removeAll()
        await state.gate.acquire()
        await state.renderer.close()
        await state.gate.release()
        guard states[id] === state else {
            throw HyperDRError(code: "cancelled", message: "Preview session was detached")
        }
        let renderer = try rendererFactory(photo)
        generationCounter += 1
        let fresh = SessionState(epoch: state.epoch, generation: generationCounter,
            photo: photo, renderer: renderer)
        states[id] = fresh
        // Frames of the old source are unreachable now (the digest is part of
        // the key); drop them so they cannot hold 256 MB of native memory.
        let digest = state.photo.sha256
        await cache.removeAll(where: { $0.session == id && $0.sourceDigest == digest })
        return fresh
    }

    private func isStaleDetach(_ epoch: UInt64, _ id: SessionID) -> Bool {
        (detachEpochs[id] ?? 0) != epoch
    }

    private func allocateSubmitOrder(_ id: SessionID) -> UInt64 {
        submitCounter += 1
        latestSubmit[id] = submitCounter
        return submitCounter
    }

    private func isLatestSubmit(_ order: UInt64, _ id: SessionID) -> Bool {
        latestSubmit[id] == order
    }

    private func prepare(_ request: PreviewRequest, state: SessionState) throws -> Prepared {
        let engineRequest = try resolver.resolve(request, session: state.photo)
        let key = try PreviewCacheKey(session: state.photo, request: engineRequest,
            buildFingerprint: buildFingerprint)
        return Prepared(request: request, engineRequest: engineRequest, key: key,
            submittedAt: ContinuousClock.now)
    }

    private func start(_ prepared: Prepared, state: SessionState) {
        guard !state.detached, states[prepared.request.session] === state else {
            eventHub.emit(.superseded(prepared.request), for: prepared.request.session)
            return
        }
        let id = prepared.request.session
        let token = UUID()
        state.inFlightToken = token
        state.inFlightPrepared = prepared
        eventHub.emit(.started(prepared.request), for: id)
        state.inFlight = Task { [weak self] in
            guard let self else { return }
            let result: Result<EngineRenderResult, Error>
            do {
                result = .success(try await self.renderEngine(prepared, state: state,
                    callerStarted: prepared.submittedAt))
            } catch {
                result = .failure(error)
            }
            await self.finish(id: id, prepared: prepared, token: token, result: result)
        }
    }

    private func finish(id: SessionID, prepared: Prepared, token: UUID,
                        result: Result<EngineRenderResult, Error>) {
        guard let state = states[id], state.inFlightToken == token else { return }
        // A later submit may have re-attributed this render to the same value;
        // publish under the newest request so the frame is never reported stale.
        let published = state.inFlightPrepared ?? prepared
        state.inFlight = nil
        state.inFlightToken = nil
        state.inFlightPrepared = nil
        switch result {
        case .success(let value):
            eventHub.emit(.finished(PreviewResult(request: published.request, frame: value.frame,
                fromCache: false, timings: value.timings)), for: id)
        case .failure(let error):
            if error is CancellationError || (error as? HyperDRError)?.code == "cancelled" {
                eventHub.emit(.superseded(published.request), for: id)
            } else {
                eventHub.emit(.failed(published.request, asHyperDRError(error)), for: id)
            }
        }
        if let pending = state.pending {
            state.pending = nil
            start(pending, state: state)
        }
    }

    /// Runs one direct render in a task the service can cancel from `detach`.
    /// Leader-only: `SingleFlight` calls this closure for the caller that owns
    /// the flight, so followers never start a second engine call.
    private func performDirectRender(_ prepared: Prepared,
                                     state: SessionState) async throws -> EngineRenderResult {
        let token = UUID()
        let work = Task {
            try await self.renderEngine(prepared, state: state,
                callerStarted: prepared.submittedAt)
        }
        state.directWork[token] = work
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            state.directWork.removeValue(forKey: token)
            return result
        } catch {
            state.directWork.removeValue(forKey: token)
            throw error
        }
    }

    private func renderEngine(_ prepared: Prepared, state: SessionState,
                              callerStarted: ContinuousClock.Instant) async throws -> EngineRenderResult {
        let clock = ContinuousClock()
        let id = prepared.request.session
        // One engine PreviewSession per photo: submit and direct render calls
        // queue here instead of racing into the engine's `busy` rejection.
        await state.gate.acquire()
        do {
            guard !Task.isCancelled, !state.detached, states[id] === state else {
                throw CancellationError()
            }
            let workStarted = clock.now
            let queued = callerStarted.duration(to: workStarted)
            var ticket: RawDecodeGate.Ticket?
            var gateWait = Duration.zero
            if state.photo.format.isRaw {
                let gateStarted = clock.now
                ticket = try await rawGate.acquire(timeout: rawDecodeTimeout)
                gateWait = gateStarted.duration(to: clock.now)
            }
            do {
                guard !Task.isCancelled, !state.detached, states[id] === state else {
                    throw CancellationError()
                }
                let engineStarted = clock.now
                let frame = try await renderWithTimeout(state.renderer, prepared.engineRequest)
                let engine = engineStarted.duration(to: clock.now)
                if let ticket { await ticket.release() }
                // Cache before releasing the session gate so detach cannot
                // clear the cache and still be followed by this put.
                await cache.put(frame, bytes: frame.previewCacheBytes, for: prepared.key)
                await state.gate.release()
                return EngineRenderResult(frame: frame, timings: PreviewTimings(
                    queued: queued, gateWait: gateWait, engine: engine))
            } catch {
                if let ticket { await ticket.release() }
                throw error
            }
        } catch {
            await state.gate.release()
            throw error
        }
    }

    private func renderWithTimeout(_ renderer: any PreviewRenderSession,
                                   _ request: EngineRequest) async throws -> PreviewFrame {
        let timeout = previewTimeout
        return try await withThrowingTaskGroup(of: PreviewFrame.self) { group in
            group.addTask { try await renderer.renderFrame(request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HyperDRError(code: "preview_timeout", message: "Preview timed out")
            }
            do {
                guard let frame = try await group.next() else {
                    throw HyperDRError(code: "internal_error", message: "Preview produced no frame")
                }
                group.cancelAll()
                return frame
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func asHyperDRError(_ error: Error) -> HyperDRError {
        if let error = error as? HyperDRError { return error }
        if error is CancellationError {
            return HyperDRError(code: "cancelled", message: "Preview cancelled")
        }
        return HyperDRError(code: "internal_error", message: "\(error)")
    }

    private static func modelAvailability(_ capabilities: Capabilities)
        -> (models: [String: Bool], defaultID: String, ready: Bool) {
        let fallbackID = "research-cnn-v1"
        guard case .object(let root) = capabilities.models,
              case .array(let entries) = root["models"] else {
            // An unreadable table means the model runtime cannot be trusted, so
            // every request is `model_not_ready` rather than `model_unknown`.
            return (models: [:], defaultID: fallbackID, ready: false)
        }
        // api.py checks the runtime first: without it every model is not ready,
        // whatever the per-entry flags say.
        var ready = false
        if case .bool(let flag) = root["runtimeAvailable"] { ready = flag }
        var result: [String: Bool] = [:]
        var firstID: String?
        for case .object(let entry) in entries {
            guard case .string(let id) = entry["id"] else { continue }
            if firstID == nil { firstID = id }
            // Python requires `available is True`; a missing flag is not a yes.
            if case .bool(let available) = entry["available"] {
                result[id] = available && ready
            } else {
                result[id] = false
            }
        }
        if case .string(let id) = root["defaultModelId"], !id.isEmpty {
            return (result, id, ready)
        }
        if let firstID { return (result, firstID, ready) }
        return (result, fallbackID, ready)
    }
}
