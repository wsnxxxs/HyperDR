import Foundation
import HyperDREngine

/// Split comparison, press-and-hold original and the scopes (batch4 §2.7,
/// §2.9). None of this is undoable; the split position lasts for this run
/// and goes back to the middle with every photo.
extension EditorModel {
    static let splitRange = 0.05...0.95

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
        scheduleDetails()
        bumpFrameRevision()
    }

    /// Release, or Esc.
    func endPeekOriginal() {
        guard isPeekingOriginal else { return }
        setPeeking(false)
        scheduleDetails()
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

    /// Recomputes the scopes off the main thread, newest frame wins. The
    /// original (reference) histogram changes with the photo and with a new
    /// original frame (the lens correction switch); draft frames never reach
    /// here.
    func startScopes(original: Bool) {
        if original, let reference = currentReferenceFrame {
            originalScopeTask?.cancel()
            let input = ScopeInput(reference)
            originalScopeTask = Task { [weak self] in
                let work = Task.detached(priority: .utility) {
                    ScopeAnalyzer.analyze(input, waveform: false)
                }
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard let self, !Task.isCancelled, let result else { return }
                scopes.update(original: .some(result.histogram), current: nil, waveform: nil)
            }
        }
        guard let frame = currentEditedFrame else { return }
        scopeTask?.cancel()
        let input = ScopeInput(frame)
        scopeTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) { ScopeAnalyzer.analyze(input, waveform: true) }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, let result else { return }
            scopes.update(original: nil, current: .some(result.histogram), waveform: .some(result.waveform))
        }
    }
}
