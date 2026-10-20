import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender
import Observation

/// The editing session shared by the Mac, iPad and iPhone (p7-2b §2, §4, §9):
/// one `Recipe`, its undo steps, drag brackets, preview render scheduling,
/// the AI prediction state and the "Original" frame. Foundation, Observation,
/// Recipe and Render only, so it can move into a package later.
///
/// The views bind to `recipe` (`setRecipe` is the binding's write) and report
/// drags through `editingChanged`; the host attaches its `UndoManager` (the
/// Mac window's, the iOS scene's) and reports the canvas size.
///
/// - Undo: each step is "recipe before → recipe after". A drag, a typed
///   value, a switch, a group reset and Reset All are one step each. View
///   state and `bypassedGroups` are never undone. A new photo clears the steps.
/// - Rendering: every change overwrites one pending request, submitted at
///   most once per display frame. A newer request cancels the render in
///   flight, except that while dragging an in-flight drag frame is allowed to
///   finish (otherwise a render slower than a frame would never be shown);
///   the newest pending value follows right after it.
/// - AI: choosing an AI source starts the prediction; until it is ready the
///   photo renders without AI and `aiStatus` is `.computing`. Editing is not
///   locked meanwhile.
@MainActor @Observable final class RecipeEditor {
    enum AIStatus: Equatable, Sendable {
        case idle
        case computing
        case ready
        /// The prediction failed; the source stays selected. Developer-facing detail.
        case failed(String)
        /// The model cannot run on this device; AI options are disabled.
        case unavailable(String)
    }

    /// The canvas long side assumed before the host reports one.
    nonisolated static let defaultCanvasSide = 2048

    // MARK: - State the views read

    private(set) var recipe: Recipe
    private(set) var source: EditorSource?
    /// The newest edited render. The previous photo's frame stays until the
    /// new photo's first frame arrives.
    private(set) var frame: EditorFrame?
    /// The photo `frame` shows: `source`, or the previous one until the new
    /// photo's first frame arrives.
    private(set) var frameSource: EditorSource?
    /// The defaults under the same development (p7-2b §5).
    private(set) var originalFrame: EditorFrame?
    private(set) var isOpening = false
    private(set) var aiStatus: AIStatus = .idle
    /// The last render failure (not a cancellation), developer-facing; nil once a render succeeds.
    private(set) var renderFailure: String?
    /// The parameter being dragged, if any.
    private(set) var editingParameter: String?
    /// The size previews are rendered at.
    private(set) var previewSize: HyperDRRender.PixelSize?

    /// Groups switched off to see their effect: a render option, never in the
    /// recipe and never undone. A new photo clears it.
    var bypassedGroups: Set<ParameterGroup> = [] {
        didSet { if bypassedGroups != oldValue { scheduleRender() } }
    }

    /// The canvas's drawable size in pixels, reported by the host.
    var canvasPixelSize: HyperDRRender.PixelSize? {
        didSet { if canvasPixelSize != oldValue { updatePreviewSize() } }
    }

    var isDragging: Bool { editingParameter != nil }

    /// Options that exist but cannot be chosen now (`AdjustmentContext.unavailableOptions`).
    var unavailableOptions: [String: Set<String>] {
        guard case .unavailable = aiStatus else { return [:] }
        return [Recipe.hdrSourceID: Set(HDRSource.allCases.filter(\.usesModel).map(\.rawValue))]
    }

    /// The shown frame lacks the AI gain its recipe asks for (computing, or until R1).
    var isModelGainPending: Bool { frame?.modelGainPending ?? false }

    /// What `auto` resolves to in the shown frame.
    var automaticValues: [String: Double] { frame?.automaticValues ?? [:] }

    // MARK: - Collaborators

    @ObservationIgnored let renderer: any EditorRendering
    @ObservationIgnored let undo: RecipeUndo
    @ObservationIgnored private let frameClock: any EditorFrameClock

    // MARK: - Bookkeeping

    @ObservationIgnored private var drag: (id: String, start: Recipe)?
    /// A drag `commitDrag` ended before its control did.
    @ObservationIgnored private var abandoned: (id: String, since: ContinuousClock.Instant)?
    @ObservationIgnored private var largestCanvasSide: Int?
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var opening: Task<EditorSource, any Error>?

    private struct Flight {
        let generation: Int
        let request: EditorRenderRequest
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var pending: EditorRenderRequest?
    @ObservationIgnored private var pacing: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Flight?
    @ObservationIgnored private var originalFlight: Flight?
    @ObservationIgnored private var renderGeneration = 0

    /// The prediction the renderer holds or is computing, by source and model.
    private struct ModelKey: Equatable { let source: UUID; let model: String }
    @ObservationIgnored private var modelKey: ModelKey?
    @ObservationIgnored private var modelTask: Task<Void, Never>?

    init(renderer: any EditorRendering, frameClock: any EditorFrameClock = ContinuousFrameClock()) {
        self.renderer = renderer
        self.frameClock = frameClock
        self.recipe = Recipe()
        var restore: (@MainActor (Recipe) -> Void)?
        self.undo = RecipeUndo(restore: { restore?($0) })
        restore = { [weak self] in self?.restore($0) }
    }

    /// Steps go to this manager from now on.
    func attach(undoManager: UndoManager?) { undo.attach(undoManager) }

    // MARK: - Photos

    /// Opens a photo the caller can read. The new photo starts from the
    /// defaults of its own input domain; undo steps, bypassed groups and the
    /// prediction state of the previous photo are dropped. A newer `open`
    /// supersedes this one, which then throws `CancellationError`.
    func open(_ url: URL) async throws {
        openGeneration += 1
        let generation = openGeneration
        isOpening = true
        defer { if generation == openGeneration { isOpening = false } }
        // Opens reach the renderer one after another, so the photo it holds
        // last is the one asked for last.
        let previous = opening
        previous?.cancel()
        let renderer = self.renderer
        let hint = Self.previewSize(source: nil, canvasSide: previewFloor(canvasPixelSize))
        let task = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            return try await renderer.open(url, previewSize: hint)
        }
        opening = task
        let opened = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        // Once the renderer holds the photo the editor shows it too, even if
        // the caller was cancelled meanwhile; only a newer request wins.
        guard generation == openGeneration else { throw CancellationError() }
        drag = nil
        abandoned = nil
        editingParameter = nil
        cancelRenders()
        undo.clear()
        previewSize = nil
        largestCanvasSide = nil
        source = opened
        recipe = Recipe(inputDomain: opened.domain)
        bypassedGroups = []
        modelTask?.cancel()
        modelTask = nil
        modelKey = nil
        if case .unavailable = aiStatus {} else { aiStatus = .idle }
        renderFailure = nil
        updatePreviewSize(force: true)
    }

    /// No photo: the empty state.
    func close() async {
        openGeneration += 1
        isOpening = false
        abandoned = nil
        // Behind any open still on its way to the renderer, ahead of any later one.
        let previous = opening
        previous?.cancel()
        let renderer = self.renderer
        let task = Task<EditorSource, any Error> {
            _ = await previous?.result
            await renderer.close()
            throw CancellationError()
        }
        opening = task
        drag = nil
        editingParameter = nil
        cancelRenders()
        undo.clear()
        source = nil
        frame = nil
        frameSource = nil
        originalFrame = nil
        recipe = Recipe()
        bypassedGroups = []
        modelTask?.cancel()
        modelTask = nil
        modelKey = nil
        previewSize = nil
        largestCanvasSide = nil
        if case .unavailable = aiStatus {} else { aiStatus = .idle }
        renderFailure = nil
        _ = await task.result
    }

    // MARK: - Edits

    /// The controls' binding write. While a drag is open the write belongs to
    /// the drag; otherwise it is one undo step, named after what changed
    /// (`RecipeEdit.classify`).
    func setRecipe(_ newValue: Recipe) {
        guard newValue != recipe, !isAbandonedWrite else { return }
        let old = recipe
        recipe = newValue
        if drag == nil, let edit = RecipeEdit.classify(from: old, to: newValue) {
            undo.register(RecipeStep(before: old, after: newValue, edit: edit))
        }
        recipeDidChange(from: old)
    }

    /// One named step. An open drag ends first, as its own step.
    func apply(_ edit: RecipeEdit, _ change: (inout Recipe) -> Void) {
        let committed = commitDrag()
        var newValue = recipe
        change(&newValue)
        guard newValue != recipe else { return }
        let old = recipe
        recipe = newValue
        // The drag and this edit are two steps even in one event's undo group.
        if committed { undo.separateNextStep() }
        undo.register(RecipeStep(before: old, after: newValue, edit: edit))
        recipeDidChange(from: old)
    }

    func resetGroup(_ group: ParameterGroup) {
        apply(.resetGroup(group)) { $0 = $0.resetting(group) }
    }

    func resetAll() {
        apply(.resetAll) { $0 = $0.resettingAll() }
    }

    /// The controls' `onEditingChanged`: true when a drag starts (the iPhone
    /// ruler's: when the finger lands), false when it ends (after its inertia
    /// stops). The whole drag is one step.
    func editingChanged(_ declaration: ParameterDeclaration, _ isEditing: Bool) {
        if !isEditing, abandoned?.id == declaration.id {
            abandoned = nil
            return
        }
        finishDrag()
        abandoned = nil
        if isEditing {
            drag = (declaration.id, recipe)
            editingParameter = declaration.id
        }
    }

    /// Ends an open drag as its own step, before something else happens to the
    /// recipe: a discrete edit, or an undo the host is about to perform (the
    /// iOS undo button tapped while the ruler still coasts). The control keeps
    /// writing until its own end; those writes are dropped, for at most
    /// `abandonedWriteLimit`, so they neither overwrite the undo nor become
    /// steps of their own. Returns whether a step was registered.
    @discardableResult
    func commitDrag() -> Bool {
        guard let id = drag?.id else { return false }
        let registered = finishDrag()
        abandoned = (id, ContinuousClock.now)
        return registered
    }

    /// How long the writes of a drag ended by `commitDrag` are dropped when
    /// the control never reports its end.
    nonisolated static let abandonedWriteLimit: Duration = .seconds(2)

    private var isAbandonedWrite: Bool {
        guard let abandoned else { return false }
        if ContinuousClock.now - abandoned.since < Self.abandonedWriteLimit { return true }
        self.abandoned = nil
        return false
    }

    @discardableResult
    private func finishDrag() -> Bool {
        guard let drag else { return false }
        self.drag = nil
        editingParameter = nil
        var registered = false
        if recipe != drag.start {
            undo.register(RecipeStep(before: drag.start, after: recipe, edit: .parameter(drag.id)))
            registered = true
        }
        // The final, non-interactive frame, and the original if development moved.
        scheduleRender()
        return registered
    }

    /// Undo and redo. A drag still open is dropped with its changes: the step
    /// being undone comes before it (hosts end drags before undoing, and a
    /// pointer or finger drag cannot overlap an undo in practice).
    private func restore(_ value: Recipe) {
        drag = nil
        editingParameter = nil
        let old = recipe
        recipe = value
        recipeDidChange(from: old)
    }

    private func recipeDidChange(from old: Recipe) {
        scheduleRender()
        updateModelGain()
    }

    // MARK: - Rendering

    private func updatePreviewSize(force: Bool = false) {
        guard let source else { return }
        let side = previewFloor(canvasPixelSize)
        largestCanvasSide = side
        let size = Self.previewSize(source: source.pixelSize, canvasSide: side)
        guard force || size != previewSize else { return }
        previewSize = size
        scheduleRender()
    }

    /// The canvas long side to size previews for: the largest seen for this
    /// photo, so shrinking a window does not render (or develop) again.
    private func previewFloor(_ canvas: HyperDRRender.PixelSize?) -> Int {
        max(canvas.map { max($0.width, $0.height) } ?? Self.defaultCanvasSide, largestCanvasSide ?? 0)
    }

    /// Render's preview tiers (`SourceResolution.preview(canvasSize:nativeSize:)`,
    /// 1280 / 2048 / 2560 / 3840, never upscaled) for a canvas whose long side
    /// is `canvasSide`. With no source yet, the tier's square: the bound for
    /// the first decode.
    nonisolated static func previewSize(source: HyperDRRender.PixelSize?, canvasSide: Int) -> HyperDRRender.PixelSize {
        let side = max(1, canvasSide)
        // An unknown source is a square far larger than any tier.
        let native = source ?? HyperDRRender.PixelSize(width: 1 << 20, height: 1 << 20)
        guard case .preview(let size)? = try? SourceResolution.preview(
            canvasSize: HyperDRRender.PixelSize(width: side, height: side), nativeSize: native) else { return native }
        return size
    }

    private func request(for recipe: Recipe, size: HyperDRRender.PixelSize, region: CGRect? = nil,
                         interactive: Bool) -> EditorRenderRequest? {
        guard let source else { return nil }
        return EditorRenderRequest(sourceID: source.id, recipe: recipe, size: size, region: region,
                                   bypassedGroups: bypassedGroups, usesModelGain: usesModelGain(recipe),
                                   isInteractive: interactive)
    }

    /// Overwrites the pending request; the pacing task submits it on the next frame.
    private func scheduleRender() {
        guard let size = previewSize,
              let request = request(for: recipe, size: size, interactive: drag != nil) else { return }
        pending = request
        if !isDragging { scheduleOriginalIfNeeded(size: size) }
        guard pacing == nil else { return }
        pacing = Task { [weak self, frameClock] in
            try? await frameClock.nextFrame()
            guard let self, !Task.isCancelled else { return }
            self.pacing = nil
            self.submitPending()
        }
    }

    private func submitPending() {
        guard let request = pending else { return }
        if let flight = inFlight {
            if flight.request == request {
                pending = nil
                return
            }
            // Let a drag frame land; `finish` submits the newest one after it.
            if flight.request.isInteractive && request.isInteractive { return }
            flight.task.cancel()
        }
        pending = nil
        renderGeneration += 1
        let generation = renderGeneration
        let renderer = self.renderer
        let task = Task { [weak self] in
            let result: Result<EditorFrame, any Error>
            do { result = .success(try await renderer.render(request)) } catch { result = .failure(error) }
            self?.finish(generation, result)
        }
        inFlight = Flight(generation: generation, request: request, task: task)
    }

    private func finish(_ generation: Int, _ result: Result<EditorFrame, any Error>) {
        guard inFlight?.generation == generation else { return }
        inFlight = nil
        switch result {
        case .success(let rendered):
            frame = rendered
            if source?.id == rendered.request.sourceID { frameSource = source }
            renderFailure = nil
        case .failure(let error):
            if !(error is CancellationError) { renderFailure = String(describing: error) }
        }
        if pending != nil, pacing == nil { submitPending() }
    }

    private func scheduleOriginalIfNeeded(size: HyperDRRender.PixelSize) {
        guard let original = request(for: recipe.original, size: size, interactive: false) else { return }
        var wanted = original
        wanted.bypassedGroups = []
        wanted.usesModelGain = false
        if let flight = originalFlight, flight.request == wanted { return }
        if originalFlight == nil, let shown = originalFrame?.request, shown == wanted { return }
        originalFlight?.task.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let renderer = self.renderer
        let task = Task { [weak self] in
            let result: Result<EditorFrame, any Error>
            do { result = .success(try await renderer.render(wanted)) } catch { result = .failure(error) }
            guard let self, self.originalFlight?.generation == generation else { return }
            self.originalFlight = nil
            if case .success(let rendered) = result { self.originalFrame = rendered }
        }
        originalFlight = Flight(generation: generation, request: wanted, task: task)
    }

    private func cancelRenders() {
        pending = nil
        pacing?.cancel()
        pacing = nil
        inFlight?.task.cancel()
        inFlight = nil
        originalFlight?.task.cancel()
        originalFlight = nil
    }

    /// A render of the current recipe outside the preview loop: a detail
    /// region at full size, a small frame for the scopes, a thumbnail.
    func render(size: HyperDRRender.PixelSize, region: CGRect? = nil) async throws -> EditorFrame {
        guard let request = request(for: recipe, size: size, region: region, interactive: false) else {
            throw EditorRenderingError.noSource
        }
        return try await renderer.render(request)
    }

    /// Where `parameterID` acts in the current recipe (R6), at `size`.
    func effectMask(parameterID: String, size: HyperDRRender.PixelSize, region: CGRect? = nil) async throws -> RenderMask {
        guard let request = request(for: recipe, size: size, region: region, interactive: false) else {
            throw EditorRenderingError.noSource
        }
        return try await renderer.effectMask(request, parameterID: parameterID)
    }

    /// An SDR thumbnail of the shown frame, or of `frame`.
    func sdrThumbnail(of frame: EditorFrame? = nil,
                      maximumSize: HyperDRRender.PixelSize = HyperDRRender.PixelSize(width: 512, height: 512)) async throws -> CGImage {
        guard let frame = frame ?? self.frame else { throw EditorRenderingError.noSource }
        return try await renderer.sdrThumbnail(frame, maximumSize: maximumSize)
    }

    // MARK: - AI

    private func wantsModel(_ recipe: Recipe) -> Bool {
        recipe.hdrSource.usesModel && recipe.conditionValue("hdr.enabled")?.boolValue != false
    }

    private func modelID(_ recipe: Recipe) -> String {
        recipe.conditionValue("hdr.model")?.stringValue ?? ""
    }

    private func usesModelGain(_ recipe: Recipe) -> Bool {
        guard wantsModel(recipe), aiStatus == .ready, let source else { return false }
        return modelKey == ModelKey(source: source.id, model: modelID(recipe))
    }

    /// Starts the prediction the recipe needs, once per photo and model. A
    /// failed prediction is not retried by itself (`retryModelGain`).
    private func updateModelGain() {
        guard wantsModel(recipe), let source else { return }
        if case .unavailable = aiStatus { return }
        let key = ModelKey(source: source.id, model: modelID(recipe))
        guard key != modelKey else { return }
        startPrediction(key)
    }

    func retryModelGain() {
        guard wantsModel(recipe), let source, case .failed = aiStatus else { return }
        startPrediction(ModelKey(source: source.id, model: modelID(recipe)))
    }

    private func startPrediction(_ key: ModelKey) {
        modelTask?.cancel()
        modelKey = key
        aiStatus = .computing
        let renderer = self.renderer
        modelTask = Task { [weak self] in
            let outcome: AIStatus
            do {
                try await renderer.predictModelGain(modelID: key.model)
                outcome = .ready
            } catch EditorRenderingError.modelUnavailable(let reason) {
                outcome = .unavailable(reason)
            } catch is CancellationError {
                return
            } catch {
                outcome = .failed(String(describing: error))
            }
            guard let self, self.modelKey == key, !Task.isCancelled else { return }
            self.modelTask = nil
            self.aiStatus = outcome
            if outcome == .ready { self.scheduleRender() }
        }
    }

    // MARK: - Tests

    /// Waits until nothing is pending, pacing, rendering or predicting.
    func settle() async {
        while true {
            if let pacing { await pacing.value; continue }
            if let flight = inFlight { await flight.task.value; await Task.yield(); continue }
            if let flight = originalFlight { await flight.task.value; await Task.yield(); continue }
            if let modelTask { await modelTask.value; await Task.yield(); continue }
            if pending != nil { submitPending(); await Task.yield(); continue }
            return
        }
    }
}
