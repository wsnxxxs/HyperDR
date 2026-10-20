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
///   locked meanwhile. A prediction belongs to one RAW development: a new
///   development (after its drag) predicts again, and a whole frame that
///   comes back without the gain it asks for starts the missing prediction.
/// - Canvas layers (step 6): when the host's `CanvasViewport` shows the photo
///   with more pixels than a frame has, a full-size render of the visible part
///   follows once the canvas has been still for `detailIdle`; while a
///   parameter with a mask is dragged, its `effectMask` follows the frames.
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
    /// The file changed on disk since it was opened: tell the user to open it again.
    private(set) var sourceChanged = false
    /// The parameter being dragged, if any.
    private(set) var editingParameter: String?
    /// The size previews are rendered at.
    private(set) var previewSize: HyperDRRender.PixelSize?
    /// Full-size renders of the visible part of `frame` and `originalFrame`;
    /// read them through `shownDetail` and `shownOriginalDetail`.
    private(set) var detailFrame: EditorFrame?
    private(set) var originalDetailFrame: EditorFrame?
    /// Where the dragged parameter acts; read it through `shownMask`.
    private(set) var effectMask: EditorMask?

    /// Groups switched off to see their effect: a render option, never in the
    /// recipe and never undone. A new photo clears it.
    var bypassedGroups: Set<ParameterGroup> = [] {
        didSet {
            guard bypassedGroups != oldValue else { return }
            scheduleRender()
            updateModelGain()
        }
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

    /// The edited detail layer, while it is of the shown frame.
    var shownDetail: EditorFrame? {
        guard let detailFrame, let frame, detailFrame.request.rendersSame(as: frame.request) else { return nil }
        return detailFrame
    }

    /// The original's detail layer, while it is of the shown original.
    var shownOriginalDetail: EditorFrame? {
        guard let originalDetailFrame, let originalFrame,
              originalDetailFrame.request.rendersSame(as: originalFrame.request) else { return nil }
        return originalDetailFrame
    }

    /// The mask of the parameter being dragged, for the photo shown. It may be
    /// a frame or two behind the drag.
    var shownMask: EditorMask? {
        guard let effectMask, effectMask.parameterID == editingParameter,
              effectMask.request.sourceID == frame?.request.sourceID else { return nil }
        return effectMask
    }

    /// While a parameter that changes only the SDR base is dragged the canvas
    /// shows the SDR version (p7-adjustments §1, §2.3).
    var previewsAsSDR: Bool {
        editingParameter.flatMap { Adjustments.declaration($0) }?.scope == .sdrOnly
    }

    // MARK: - Collaborators

    @ObservationIgnored let renderer: any EditorRendering
    @ObservationIgnored let undo: RecipeUndo
    @ObservationIgnored private let frameClock: any EditorFrameClock
    /// How long the canvas must be still before a detail region is rendered.
    @ObservationIgnored let detailIdle: Duration

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
    private struct ModelKey: Equatable {
        let source: UUID
        let model: String
        let development: [String: ParameterValue]
        let bypassed: Set<ParameterGroup>
    }
    /// The prediction in flight.
    @ObservationIgnored private var modelKey: ModelKey?
    /// Predictions made, oldest first, at most `predictionLimit`.
    @ObservationIgnored private var predicted: [ModelKey] = []
    @ObservationIgnored private var failure: (key: ModelKey, reason: String)?
    /// A prediction asked for again because a frame lacked it; not again
    /// until a frame has shown it.
    @ObservationIgnored private var repredicted: ModelKey?
    @ObservationIgnored private var modelTask: Task<Void, Never>?

    @ObservationIgnored private var viewport: CanvasViewport?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var detailGeneration = 0
    @ObservationIgnored private var maskTask: Task<Void, Never>?
    /// The last mask asked for, so a failed one is not asked again for the same frame.
    @ObservationIgnored private var maskAttempt: (parameterID: String, request: EditorRenderRequest)?

    init(renderer: any EditorRendering, frameClock: any EditorFrameClock = ContinuousFrameClock(),
         detailIdle: Duration = .milliseconds(250)) {
        self.renderer = renderer
        self.frameClock = frameClock
        self.detailIdle = detailIdle
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
        // A caller cancelled before it got here must not supersede a newer open.
        try Task.checkCancellation()
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
        clearLayers()
        undo.clear()
        previewSize = nil
        largestCanvasSide = nil
        source = opened
        sourceChanged = false
        recipe = Recipe(inputDomain: opened.domain)
        bypassedGroups = []
        modelTask?.cancel()
        modelTask = nil
        modelKey = nil
        predicted = []
        failure = nil
        repredicted = nil
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
        clearLayers()
        undo.clear()
        source = nil
        sourceChanged = false
        frame = nil
        frameSource = nil
        originalFrame = nil
        recipe = Recipe()
        bypassedGroups = []
        modelTask?.cancel()
        modelTask = nil
        modelKey = nil
        predicted = []
        failure = nil
        repredicted = nil
        previewSize = nil
        largestCanvasSide = nil
        if case .unavailable = aiStatus {} else { aiStatus = .idle }
        renderFailure = nil
        _ = await task.result
    }

    // MARK: - Edits

    /// The controls' binding write. While a drag is open the write belongs to
    /// the drag; otherwise it is one undo step, named after what changed
    /// (`RecipeEdit.classify`). A write from a drag `commitDrag` abandoned
    /// keeps everything but that control's value.
    func setRecipe(_ newValue: Recipe) {
        var newValue = newValue
        if let id = abandonedID {
            newValue.setValue(recipe.value(for: id), for: id)
        }
        guard newValue != recipe else { return }
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
            detailTask?.cancel()
            updateMask()
        }
    }

    /// Ends an open drag as its own step, before something else happens to the
    /// recipe: a discrete edit, or an undo the host is about to perform (the
    /// iOS undo button tapped while the ruler still coasts). The control keeps
    /// writing until its own end; its changes to its own parameter are
    /// dropped, for at most `abandonedWriteLimit`, so they neither overwrite
    /// the undo nor become steps of their own. Every other control writes as
    /// usual meanwhile. Returns whether a step was registered.
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

    /// The parameter whose writes are dropped now, if any.
    private var abandonedID: String? {
        guard let abandoned else { return nil }
        if ContinuousClock.now - abandoned.since < Self.abandonedWriteLimit { return abandoned.id }
        self.abandoned = nil
        return nil
    }

    @discardableResult
    private func finishDrag() -> Bool {
        guard let drag else { return false }
        self.drag = nil
        editingParameter = nil
        updateMask()
        var registered = false
        if recipe != drag.start {
            undo.register(RecipeStep(before: drag.start, after: recipe, edit: .parameter(drag.id)))
            registered = true
        }
        // The final, non-interactive frame, and the original if development
        // moved; a new development's prediction starts now.
        scheduleRender()
        updateModelGain()
        return registered
    }

    /// Undo and redo. A drag still open is dropped with its changes: the step
    /// being undone comes before it (hosts end drags before undoing, and a
    /// pointer or finger drag cannot overlap an undo in practice).
    private func restore(_ value: Recipe) {
        drag = nil
        editingParameter = nil
        updateMask()
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
        detailTask?.cancel()
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
            if let detail = detailFrame, !detail.request.rendersSame(as: rendered.request) { detailFrame = nil }
            updateMask()
            frameLacksModelGain(rendered)
        case .failure(let error):
            if !(error is CancellationError) { renderFailure = String(describing: error) }
            noteFailure(error)
        }
        if pending != nil, pacing == nil { submitPending() }
        scheduleDetails()
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
            if case .success(let rendered) = result {
                self.originalFrame = rendered
                if let detail = self.originalDetailFrame, !detail.request.rendersSame(as: rendered.request) {
                    self.originalDetailFrame = nil
                }
                self.scheduleDetails()
            }
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

    // MARK: - Canvas layers

    /// What the canvas shows, from the host on every pan, zoom, resize and
    /// view change; nil when no photo is drawn. A detail no longer needed, or
    /// one that no longer covers the visible part, is dropped at once; a new
    /// one is asked for once the canvas is still.
    func setViewport(_ viewport: CanvasViewport?) {
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        if let detail = detailFrame, !keeps(detail, of: frame, showing: viewport?.showsEdited) { detailFrame = nil }
        if let detail = originalDetailFrame, !keeps(detail, of: originalFrame, showing: viewport?.showsOriginal) {
            originalDetailFrame = nil
        }
        scheduleDetails()
    }

    private func keeps(_ detail: EditorFrame, of frame: EditorFrame?, showing: Bool?) -> Bool {
        guard let viewport, showing == true, let frame, lacksPixels(frame, viewport),
              let region = detail.request.region else { return false }
        return Self.covers(region, viewport.visible)
    }

    /// Within half a pixel: the visible rect is fractional, regions are whole.
    private static func covers(_ region: CGRect, _ visible: CGRect) -> Bool {
        region.insetBy(dx: -0.5, dy: -0.5).contains(visible)
    }

    /// Whether the canvas draws `frame` with more pixels than it has, and the
    /// source has more to give.
    private func lacksPixels(_ frame: EditorFrame, _ viewport: CanvasViewport) -> Bool {
        guard let source, frame.request.sourceID == source.id else { return false }
        let width = Double(frame.display.outputSize.width) + 0.5
        return width < Double(source.pixelSize.width) && width < viewport.displayedWidth
    }

    /// Asks for the details the viewport needs, after `detailIdle`, once the
    /// shown frames are final (no drag, nothing pending or rendering).
    private func scheduleDetails() {
        detailTask?.cancel()
        detailTask = nil
        guard let source, let viewport, !isDragging, pending == nil, pacing == nil, inFlight == nil,
              !viewport.visible.isEmpty else { return }
        let region = Self.detailRegion(visible: viewport.visible, source: source.pixelSize)
        func wanted(_ frame: EditorFrame?, _ detail: EditorFrame?, shown: Bool) -> EditorRenderRequest? {
            guard shown, let frame, lacksPixels(frame, viewport) else { return nil }
            if let detail, detail.request.rendersSame(as: frame.request),
               let covered = detail.request.region, Self.covers(covered, viewport.visible) { return nil }
            var request = frame.request
            request.size = source.pixelSize
            request.region = region
            request.isInteractive = false
            return request
        }
        let original = originalFlight == nil ? wanted(originalFrame, originalDetailFrame, shown: viewport.showsOriginal) : nil
        let edited = wanted(frame, detailFrame, shown: viewport.showsEdited)
        guard original != nil || edited != nil else { return }
        detailGeneration += 1
        let generation = detailGeneration
        let renderer = self.renderer, idle = detailIdle
        detailTask = Task { [weak self] in
            try? await Task.sleep(for: idle)
            for (isOriginal, request) in [(true, original), (false, edited)] {
                guard !Task.isCancelled else { return }
                guard let request else { continue }
                let rendered: EditorFrame
                do { rendered = try await renderer.render(request) } catch {
                    if !Task.isCancelled { self?.noteFailure(error) }
                    return
                }
                guard let self, self.detailGeneration == generation, !Task.isCancelled else { return }
                if isOriginal { self.originalDetailFrame = rendered } else { self.detailFrame = rendered }
            }
            guard let self, self.detailGeneration == generation else { return }
            self.detailTask = nil
        }
    }

    nonisolated static let detailExpansion = 0.25
    nonisolated static let detailMinimumEdge = 2048.0

    /// The visible part, grown by `detailExpansion` on each side for small
    /// pans (each edge at most `detailMinimumEdge` or the visible edge,
    /// whichever is larger), in whole pixels inside the source.
    nonisolated static func detailRegion(visible: CGRect, source: HyperDRRender.PixelSize) -> CGRect {
        let sourceWidth = Double(source.width), sourceHeight = Double(source.height)
        func edge(_ visible: Double, _ limit: Double) -> Double {
            min(limit, max(min(detailMinimumEdge, visible * (1 + 2 * detailExpansion)), ceil(visible)))
                .rounded(.up)
        }
        let width = min(sourceWidth, edge(visible.width, sourceWidth))
        let height = min(sourceHeight, edge(visible.height, sourceHeight))
        let x = min(max(0, (visible.midX - width / 2).rounded(.down)), sourceWidth - width)
        let y = min(max(0, (visible.midY - height / 2).rounded(.down)), sourceHeight - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Follows the dragged parameter's mask: one at a time, then again for the
    /// newest frame if it moved on meanwhile.
    private func updateMask() {
        guard let id = editingParameter, Adjustments.declaration(id)?.mask != nil,
              let frame, frame.request.sourceID == source?.id else {
            maskTask?.cancel()
            maskTask = nil
            maskAttempt = nil
            effectMask = nil
            return
        }
        guard maskTask == nil else { return }
        var request = frame.request
        request.region = nil
        request.isInteractive = false
        if let attempt = maskAttempt, attempt.parameterID == id, attempt.request.rendersSame(as: request) { return }
        maskAttempt = (id, request)
        let renderer = self.renderer
        maskTask = Task { [weak self] in
            var mask: RenderMask?
            do { mask = try await renderer.effectMask(request, parameterID: id) } catch {
                if !Task.isCancelled { self?.noteFailure(error) }
            }
            guard let self, !Task.isCancelled else { return }
            self.maskTask = nil
            if let mask, self.editingParameter == id {
                self.effectMask = EditorMask(parameterID: id, request: request, mask: mask)
            }
            self.updateMask()
        }
    }

    private func noteFailure(_ error: any Error) {
        if case EditorRenderingError.sourceChanged = error { sourceChanged = true }
    }

    private func clearLayers() {
        detailTask?.cancel()
        detailTask = nil
        detailFrame = nil
        originalDetailFrame = nil
        maskTask?.cancel()
        maskTask = nil
        maskAttempt = nil
        effectMask = nil
    }

    // MARK: - AI

    private func wantsModel(_ recipe: Recipe) -> Bool {
        recipe.hdrSource.usesModel && recipe.conditionValue("hdr.enabled")?.boolValue != false
    }

    private func modelID(_ recipe: Recipe) -> String {
        recipe.conditionValue("hdr.model")?.stringValue ?? ""
    }

    /// The prediction a recipe needs: by photo, model and the development the
    /// renderer predicts on (a new RAW development is a new source for
    /// Render, so its prediction is a new one; preview and full size share it).
    private func modelKey(_ recipe: Recipe, bypassed: Set<ParameterGroup>) -> ModelKey? {
        guard wantsModel(recipe), let source else { return nil }
        return ModelKey(source: source.id, model: modelID(recipe), development: recipe.development, bypassed: bypassed)
    }

    private var currentModelKey: ModelKey? { modelKey(recipe, bypassed: bypassedGroups) }

    private func usesModelGain(_ recipe: Recipe) -> Bool {
        guard let key = modelKey(recipe, bypassed: bypassedGroups) else { return false }
        return predicted.contains(key)
    }

    /// Follows the prediction the current recipe needs: ready if it was made,
    /// computing while it is, started when it is not (after a drag, not
    /// during one). A failed prediction is not retried by itself (`retryModelGain`).
    private func updateModelGain() {
        guard let key = currentModelKey else { return }
        if case .unavailable = aiStatus { return }
        if predicted.contains(key) {
            aiStatus = .ready
        } else if let failure, failure.key == key {
            aiStatus = .failed(failure.reason)
        } else {
            aiStatus = .computing
            if modelKey != key, !isDragging { startPrediction(key) }
        }
    }

    /// A whole frame came back without the AI gain it asks for: the renderer
    /// has no prediction for the source it rendered from. Predict for it,
    /// also when the renderer lost one it had (Render gives a development a
    /// new source id each time it is loaded again), but not again before a
    /// frame has shown it.
    private func frameLacksModelGain(_ frame: EditorFrame) {
        guard frame.modelGainPending else {
            if frame.request.usesModelGain { repredicted = nil }
            return
        }
        guard frame.request.region == nil, !isDragging, modelKey == nil,
              let key = currentModelKey,
              key == modelKey(frame.request.recipe, bypassed: frame.request.bypassedGroups) else { return }
        if frame.request.usesModelGain {
            guard repredicted != key else { return }
            repredicted = key
            predicted.removeAll { $0 == key }
        }
        updateModelGain()
    }

    func retryModelGain() {
        guard let key = currentModelKey, case .failed = aiStatus else { return }
        if failure?.key == key { failure = nil }
        updateModelGain()
    }

    private func startPrediction(_ key: ModelKey) {
        guard let size = previewSize ?? source?.pixelSize,
              let request = request(for: recipe, size: size, interactive: false) else { return }
        modelTask?.cancel()
        modelKey = key
        aiStatus = .computing
        let renderer = self.renderer
        modelTask = Task { [weak self] in
            var reason: String?
            do {
                try await renderer.predictModelGain(request)
            } catch EditorRenderingError.modelUnavailable(let detail) {
                guard let self, self.modelKey == key, !Task.isCancelled else { return }
                self.modelTask = nil
                self.modelKey = nil
                self.aiStatus = .unavailable(detail)
                return
            } catch is CancellationError {
                return
            } catch {
                reason = String(describing: error)
                if !Task.isCancelled { self?.noteFailure(error) }
            }
            guard let self, self.modelKey == key, !Task.isCancelled else { return }
            self.modelTask = nil
            self.modelKey = nil
            if let reason {
                self.failure = (key, reason)
            } else {
                self.predicted.removeAll { $0 == key }
                self.predicted.append(key)
                if self.predicted.count > Self.predictionLimit { self.predicted.removeFirst() }
            }
            // The recipe may have moved on to another development meanwhile.
            self.updateModelGain()
            if reason == nil { self.scheduleRender() }
        }
    }

    /// Predictions the editor counts on; `RenderSession` keeps as many.
    nonisolated static let predictionLimit = 4

    // MARK: - Tests

    /// Waits until nothing is pending, pacing, rendering or predicting.
    func settle() async {
        while true {
            if let pacing { await pacing.value; continue }
            if let flight = inFlight { await flight.task.value; await Task.yield(); continue }
            if let flight = originalFlight { await flight.task.value; await Task.yield(); continue }
            if let modelTask { await modelTask.value; await Task.yield(); continue }
            if let maskTask { await maskTask.value; await Task.yield(); continue }
            if let detailTask { await detailTask.value; await Task.yield(); continue }
            if pending != nil { submitPending(); await Task.yield(); continue }
            return
        }
    }
}

/// What the canvas shows, as the editor needs it for detail regions.
nonisolated struct CanvasViewport: Equatable, Sendable {
    /// The part of the photo on screen, in full-size source pixels, top left origin.
    var visible: CGRect
    /// How many device pixels wide the whole photo is drawn.
    var displayedWidth: Double
    /// Which renditions are on screen (the original while held, in split, or
    /// chosen; the edit otherwise).
    var showsEdited = true
    var showsOriginal = false
}
