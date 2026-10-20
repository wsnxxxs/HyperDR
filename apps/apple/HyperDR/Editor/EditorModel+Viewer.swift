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
        switch viewMode {
        case .compare: return "canvas.hint.split"
        case .original: return nil
        case .edited: return canvas.canZoomOut ? "canvas.hint.pan" : (hasReferenceFrame ? "canvas.hint.peek" : nil)
        }
    }

    // MARK: - Scopes

    /// Recomputes the scopes from a small render of the current recipe, off
    /// the main thread, once the edit has settled (never during a drag). The
    /// original's histogram changes only when the original does (a new photo,
    /// a new development).
    func startScopes() {
        guard let source = editor.source else { return }
        let recipe = editor.recipe
        let size = Self.scopeSize(source.pixelSize)
        let editor = self.editor
        if scopedOriginal != recipe.original {
            scopedOriginal = recipe.original
            originalScopeTask?.cancel()
            originalScopeTask = Task { [weak self] in
                guard let result = await Self.analyze(editor: editor, size: size, original: true, waveform: false),
                      let self, !Task.isCancelled else { return }
                scopes.update(original: .some(result.histogram), current: nil, waveform: nil)
            }
        }
        guard scopedRecipe != recipe else { return }
        scopedRecipe = recipe
        scopeTask?.cancel()
        scopeTask = Task { [weak self] in
            guard let result = await Self.analyze(editor: editor, size: size, original: false, waveform: true),
                  let self, !Task.isCancelled else { return }
            scopes.update(original: nil, current: .some(result.histogram), waveform: .some(result.waveform))
        }
    }

    private static func analyze(editor: RecipeEditor, size: HyperDRRender.PixelSize, original: Bool,
                                waveform: Bool) async -> ScopeAnalyzer.Result? {
        guard let frame = try? await editor.render(size: size, original: original), !Task.isCancelled else { return nil }
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
