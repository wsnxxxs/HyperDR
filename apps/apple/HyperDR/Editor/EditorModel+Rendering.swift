import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender

extension EditorModel {
    /// Describes the frame actually on the canvas, independently of how much
    /// HDR the current screen can show. A pending edit keeps the old frame's badge.
    var showsHDRBadge: Bool {
        _ = frameRevision
        guard hasEditedFrame, !previewsAsSDR, !editor.previewsAsSDR else { return false }
        if let editedFrame { return editedFrame.hasHDRContent }
        // SwiftUI preview scenarios have display facts without GPU frames.
        return document?.source?.domain == .hdr || document?.source?.domain == .dual || display.gainWeight != nil
    }

    /// The HDR ceiling the overlays and the mask measure against: what the
    /// edit's alternate rendition reaches, in stops.
    var outputCeilingStops: Double {
        _ = frameRevision
        return max(0, editedPair?.alternateHeadroom ?? 0)
    }

    var canvasComposition: CanvasComposition? {
        guard let edited = editedPair ?? referencePair else { return nil }
        let mode: CanvasComposition.Mode = !hasEditedFrame || isPeekingOriginal || viewMode == .original ? .original
            : (viewMode == .compare ? .compare : .edited)
        return CanvasComposition(original: referencePair, edited: edited,
            originalDetail: originalDetailPair, editedDetail: editedDetailPair,
            mode: referencePair == nil ? .edited : mode, splitRatio: splitRatio,
            headroom: display.currentHeadroom,
            overlays: CanvasOverlays(highlights: showsHighlightZebra, shadows: showsShadowZebra,
                                     hdrRange: Float(outputCeilingStops)),
            effectMask: effectMask, previewsAsSDR: previewsAsSDR || editor.previewsAsSDR)
    }

    /// The full-size renders of the visible part (the editor's detail
    /// layers), while they are of the frames shown.
    var editedDetailPair: DisplayPair? { editor.shownDetail.map { DisplayPair($0.display) } }
    var originalDetailPair: DisplayPair? { editor.shownOriginalDetail.map { DisplayPair($0.display) } }

    /// Where the dragged parameter acts, tinted over the edited side.
    var effectMask: DisplayMask? { editor.shownMask.map { DisplayMask($0.mask) } }

    /// No detail layers until the canvas is next reported.
    func invalidateDetails() { editor.setViewport(nil) }

    /// Called by CanvasModel for buttons, gestures, viewport and scale
    /// changes, and on every change of what is shown: the editor asks for
    /// the details the canvas lacks once it is still.
    func canvasGeometryChanged() {
        editor.setViewport(canvasViewport)
    }

    /// What the canvas shows, in full-size source pixels; nil before the
    /// photo is committed or while its source is unavailable.
    private var canvasViewport: CanvasViewport? {
        guard photo != nil, !isEditingLocked, sourceUnavailable == nil, let source = editor.source,
              source.id == committedSource,
              canvas.transform.imageSize == CGSize(width: source.pixelSize.width, height: source.pixelSize.height),
              let visible = canvas.visibleSourceRect else { return nil }
        let transform = canvas.transform
        return CanvasViewport(visible: visible,
                              displayedWidth: Double(transform.displayedSize.width * transform.backingScale),
                              showsEdited: !isPeekingOriginal && viewMode != .original,
                              showsOriginal: isPeekingOriginal || viewMode != .edited)
    }
}
