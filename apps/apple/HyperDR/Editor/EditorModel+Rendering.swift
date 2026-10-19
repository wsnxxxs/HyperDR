import CoreGraphics
import Foundation
import HyperDREngine
import HyperDRKit

/// Conservative starting values, pending A3 measurements. §4 leaves the
/// idle duration open; 250 ms avoids scheduling regions during active pans.
nonisolated enum DetailPolicy {
    static let idle: Duration = .milliseconds(250)
    static let expansion = 0.25
    static let maxEdge = 2048

    static func region(visible: CGRect, source: CGSize) -> PreviewRegion {
        let width = min(maxEdge, Int(ceil(visible.width * (1 + 2 * expansion))), Int(source.width))
        let height = min(maxEdge, Int(ceil(visible.height * (1 + 2 * expansion))), Int(source.height))
        let x = min(max(0, Int(floor(visible.midX - Double(width) / 2))), Int(source.width) - width)
        let y = min(max(0, Int(floor(visible.midY - Double(height) / 2))), Int(source.height) - height)
        return PreviewRegion(left: x, top: y, width: width, height: height)
    }
}

extension EditorModel {
    func showMask(for key: String) {
        guard !isEditingLocked, controlValues[key]?.spec.hasMask == true, controlValues[key]?.isVisible == true else { return }
        if maskKey != key { setMaskKey(key); bumpFrameRevision() }
    }

    func hideMask() {
        if maskKey != nil { setMaskKey(nil); bumpFrameRevision() }
    }

    /// Observable through the control/AI/workflow/frame properties it reads.
    /// Scopes and the renderer use this same output ceiling.
    var outputCeilingStops: Double {
        _ = frameRevision
        if workflow == .colorOnly { return 0 }
        if ai.mode == .optimized {
            let value = control("aiHdrRange").value
            return value < 0 ? currentEditedFrame?.metadata.headroomStops ?? 0 : value
        }
        return control("hdrRange").value
    }

    var canvasComposition: CanvasComposition? {
        guard let edited = currentEditedFrame ?? currentReferenceFrame else { return nil }
        let mode: CanvasComposition.Mode = !hasEditedFrame || isPeekingOriginal || viewMode == .original ? .original
            : (viewMode == .compare ? .compare : .edited)
        return CanvasComposition(original: currentReferenceFrame, edited: edited,
            originalDetail: originalDetailFrame, editedDetail: editedDetailFrame,
            mode: currentReferenceFrame == nil ? .edited : mode, splitRatio: splitRatio,
            headroom: display.currentHeadroom,
            overlays: CanvasOverlays(highlights: showsHighlightZebra, shadows: showsShadowZebra,
                                     mask: maskKey != nil, hdrRange: Float(outputCeilingStops)), previewsAsSDR: previewsAsSDR,
            presentationTrace: mode == .original ? referencePresentationTrace : editedPresentationTrace,
            originalDetailTrace: originalDetailTrace, editedDetailTrace: editedDetailTrace)
    }

    func invalidateDetails(editedOnly: Bool = false) {
        detailTask?.cancel(); detailTask = nil
        detailTicket &+= 1
        editedDetailTrace = nil
        if !editedOnly { originalDetailTrace = nil }
        if editedDetailFrame != nil { editedDetailFrame = nil; editedDetailTrace = nil; bumpFrameRevision() }
        if !editedOnly, originalDetailFrame != nil { originalDetailFrame = nil; originalDetailTrace = nil; bumpFrameRevision() }
    }

    /// The details of the "original" only; the edit's details stay up.
    func invalidateOriginalDetail() {
        guard originalDetailFrame != nil || originalDetailTrace != nil else { return }
        detailTask?.cancel(); detailTask = nil
        detailTicket &+= 1
        originalDetailTrace = nil
        if originalDetailFrame != nil { originalDetailFrame = nil; bumpFrameRevision() }
    }

    /// Called by CanvasModel for buttons, gestures, viewport and scale changes.
    func canvasGeometryChanged() {
        guard canvas.needsEditedDetail || canvas.needsOriginalDetail, let visible = canvas.visibleSourceRect else {
            invalidateDetails()
            return
        }
        if let frame = editedDetailFrame, CanvasCompositor.region(frame)?.contains(visible) != true {
            editedDetailFrame = nil; editedDetailTrace = nil; bumpFrameRevision()
        }
        if let frame = originalDetailFrame, CanvasCompositor.region(frame)?.contains(visible) != true {
            originalDetailFrame = nil; originalDetailTrace = nil; bumpFrameRevision()
        }
        scheduleDetails()
    }

    func scheduleDetails() {
        detailTask?.cancel()
        detailTicket &+= 1
        guard !isEditingLocked, !renderOutstanding, gesture == nil, !lastSubmitWasDraft,
              sourceUnavailable == nil || isRetryingSource,
              canvas.needsEditedDetail || canvas.needsOriginalDetail,
              let visible = canvas.visibleSourceRect, let photo else { return }
        let ticket = detailTicket
        let region = DetailPolicy.region(visible: visible, source: canvas.transform.imageSize)
        let options = effectiveOptions()
        let wantsOriginal = isPeekingOriginal || viewMode != .edited
        let wantsEdited = !isPeekingOriginal && viewMode != .original
        let reference = referenceOptions ?? EditDefaults.reference(encoding: edit.encoding, workflow: options)
        // Each side asks for a detail only when its own frame is too small: the
        // original may be a tier behind the edit (V-13), and none is asked of an
        // original that is being replaced.
        let needsOriginal = wantsOriginal && originalDetailFrame == nil && canvas.needsOriginalDetail
            && !isReferenceRenderPending
        let needsEdited = wantsEdited && editedDetailFrame == nil && canvas.needsEditedDetail
        guard needsOriginal || needsEdited else { return }
        detailTask = Task { [weak self, services] in
            do {
                try await Task.sleep(for: DetailPolicy.idle)
                if needsOriginal {
                    let result = try await services.renderDetail(photo, options: reference, region: region, original: true)
                    guard let self, !Task.isCancelled, detailTicket == ticket, self.photo == photo else { return }
                    if let frame = result?.frame { originalDetailFrame = frame; originalDetailTrace = result?.trace; bumpFrameRevision() }
                }
                if needsEdited {
                    let result = try await services.renderDetail(photo, options: options, region: region, original: false)
                    guard let self, !Task.isCancelled, detailTicket == ticket, self.photo == photo else { return }
                    if let frame = result?.frame { editedDetailFrame = frame; editedDetailTrace = result?.trace; bumpFrameRevision() }
                }
            } catch EditorDetailError.sourceReplaced {
                guard let self, !Task.isCancelled, detailTicket == ticket, self.photo == photo else { return }
                reopenReplacedSource(photo)
            } catch {
                // The whole-frame preview stays visible; another pan or edit
                // can retry. A file that cannot be found is said once.
                guard let self, !Task.isCancelled, detailTicket == ticket, self.photo == photo else { return }
                enterSourceUnavailable(UserFacingError.service(error))
            }
        }
    }
}
