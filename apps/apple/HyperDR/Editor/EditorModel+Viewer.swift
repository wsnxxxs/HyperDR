import Foundation
import HyperDRRecipe
import HyperDRRender

/// Split comparison, press-and-hold original and the scopes (batch4 §2.7,
/// §2.9). None of this is undoable; the split position lasts for this run
/// and goes back to the middle with every photo.
extension EditorModel {
    static let splitRange = 0.05...0.95
    /// The long side of the render the scopes read (p7-2b §3.1).
    static let scopeEdge = 512

    func setSplitRatio(_ value: Double) {
        guard value.isFinite else { return }
        setSplitRatioValue(min(Self.splitRange.upperBound, max(Self.splitRange.lowerBound, value)))
    }

    /// Arrow keys on the focused divider: ±0.05.
    func nudgeSplit(by delta: Double) { setSplitRatio(splitRatio + delta) }

    /// The C key and the View menu item.
    func toggleCompare() {
        if viewMode == .compare { viewMode = .edited }
        else if isAvailable(.compare) { viewMode = .compare }
    }

    /// Press and hold on the canvas, or hold Space while it has focus. The
    /// 240 ms and 4 pt rules live in the view layer.
    func beginPeekOriginal() {
        guard hasReferenceFrame, hasEditedFrame, !isPeekingOriginal else { return }
        setPeeking(true)
        canvasGeometryChanged()
        bumpFrameRevision()
    }

    /// Release, or Esc.
    func endPeekOriginal() {
        guard isPeekingOriginal else { return }
        setPeeking(false)
        canvasGeometryChanged()
        bumpFrameRevision()
    }

    /// The hint under the canvas for what can be done now (PC V-08).
    var viewerHintKey: String? {
        guard document != nil, hasEditedFrame else { return nil }
        if isPeekingOriginal { return "canvas.peeking" }
        if isCropping { return "canvas.hint.crop" }
        switch viewMode {
        case .compare: return "canvas.hint.split"
        case .original: return nil
        case .edited: return canvas.canZoomOut ? "canvas.hint.pan" : (hasReferenceFrame ? "canvas.hint.peek" : nil)
        }
    }

    // MARK: - Scopes

    /// Recomputes the scopes from a small render of what the canvas shows,
    /// off the main thread, once the edit has settled (never during a drag).
    /// A render is measured again only when it would draw another picture:
    /// another source, recipe, bypass, or the prediction coming in. The
    /// original's histogram changes only when the original does.
    func startScopes() {
        guard let source = editor.source else { return }
        let size = Self.scopeSize(editor.canvasPhotoSize ?? source.pixelSize)
        let editor = self.editor
        if let request = editor.renderRequest(size: size, original: true), wantsMeasuring(request, original: true) {
            scopingOriginal = request
            originalScopeTask?.cancel()
            originalScopeTask = Task { [weak self] in
                let result = await Self.analyze(editor: editor, request: request, waveform: false)
                // Only the measurement still asked for is published (R34-001).
                guard let self, !Task.isCancelled, scopingOriginal == request else { return }
                scopingOriginal = nil
                guard let result else { return }
                scopedOriginal = request
                scopes.update(original: .some(result.histogram), current: nil, waveform: nil)
            }
        }
        guard let request = editor.renderRequest(size: size), wantsMeasuring(request, original: false) else { return }
        scopingRequest = request
        scopeTask?.cancel()
        scopeTask = Task { [weak self] in
            let result = await Self.analyze(editor: editor, request: request, waveform: true)
            guard let self, !Task.isCancelled, scopingRequest == request else { return }
            scopingRequest = nil
            guard let result else { return }
            scopedRequest = request
            scopes.update(original: nil, current: .some(result.histogram), waveform: .some(result.waveform))
        }
    }

    /// Whether `request` needs a new measurement. What was measured already
    /// stands, and a measurement of another picture still running is dropped
    /// (A → B → A: B's result must not replace A's); one of this picture
    /// still running is waited for.
    private func wantsMeasuring(_ request: EditorRenderRequest, original: Bool) -> Bool {
        let measured = original ? scopedOriginal : scopedRequest
        let measuring = original ? scopingOriginal : scopingRequest
        if let measuring, measuring.rendersSame(as: request) { return false }
        guard measured?.rendersSame(as: request) == true else { return true }
        if measuring != nil {
            if original { originalScopeTask?.cancel(); scopingOriginal = nil }
            else { scopeTask?.cancel(); scopingRequest = nil }
        }
        return false
    }

    private static func analyze(editor: RecipeEditor, request: EditorRenderRequest,
                                waveform: Bool) async -> ScopeAnalyzer.Result? {
        guard let frame = try? await editor.renderer.render(request), !Task.isCancelled else { return nil }
        let display = frame.display
        let work = Task.detached(priority: .utility) { () -> ScopeAnalyzer.Result? in
            guard let input = try? await ScopeInput.read(display) else { return nil }
            return ScopeAnalyzer.analyze(input, waveform: waveform)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// `source` fitted into `scopeEdge`, never enlarged.
    static func scopeSize(_ source: HyperDRRender.PixelSize) -> HyperDRRender.PixelSize {
        let long = max(source.width, source.height)
        guard long > scopeEdge else { return source }
        let scale = Double(scopeEdge) / Double(long)
        return HyperDRRender.PixelSize(width: max(1, Int((Double(source.width) * scale).rounded())),
                                       height: max(1, Int((Double(source.height) * scale).rounded())))
    }
}
