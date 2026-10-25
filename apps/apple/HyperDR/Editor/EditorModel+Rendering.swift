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

    /// The HDR ceiling the overlays measure against: what the
    /// edit's alternate rendition reaches, in stops.
    var outputCeilingStops: Double {
        _ = frameRevision
        return max(0, editedPair?.alternateHeadroom ?? 0)
    }

    var canvasComposition: CanvasComposition? {
        guard let edited = editedPair ?? referencePair else { return nil }
        let mode: CanvasComposition.Mode = !hasEditedFrame || isPeekingOriginal || viewMode == .original ? .original
            : (viewMode == .compare ? .compare : .edited)
        let crop = cropLayout
        return CanvasComposition(original: referencePair, edited: edited,
            originalDetail: originalDetailPair, editedDetail: editedDetailPair,
            mode: referencePair == nil || crop != nil ? .edited : mode, splitRatio: splitRatio,
            headroom: display.currentHeadroom,
            overlays: CanvasOverlays(highlights: showsHighlightZebra, shadows: showsShadowZebra,
                                     hdrRange: Float(outputCeilingStops)),
            previewsAsSDR: previewsAsSDR || editor.previewsAsSDR,
            geometry: crop?.display(clipsToCrop: !isCropping, dimsOutsideCrop: isCropping,
                                    rendered: editedFrame?.request.recipe.geometry ?? .identity),
            clipping: clippingMasks)
    }

    /// Render's dead black and clipping masks, while the editor shows them
    /// (a white or black point drag, or the Option key held).
    var clippingMasks: ClippingMasks? {
        guard editor.showsClipping, !isCropping else { return nil }
        let masks = ClippingMasks(whole: editor.clippingMask?.texture, detail: editor.detailClippingMask?.texture)
        return masks.isEmpty ? nil : masks
    }

    /// Room around the crop in the crop pane, for its corners.
    static let cropMargin: CGFloat = 40

    /// The crop pane's placement of the photo, drawn from whatever frame is
    /// shown (on entering, the cropped one lands on its crop until the whole
    /// photo arrives); also, once the pane is left, until the cropped frame
    /// arrives (the whole photo drawn through the crop, so it never shows
    /// uncropped). Nil outside the pane when the frame shown is not the whole photo.
    var cropLayout: CropLayout? {
        let viewport = canvas.transform.viewport
        guard let frame = editedFrame, let source = editor.source, frame.request.sourceID == source.id,
              CropLayout.drawsThroughGeometry(shown: frame.request.recipe.geometry, recipe: editor.recipe.geometry,
                                              cropping: isCropping),
              viewport.width > 0, viewport.height > 0 else { return nil }
        if isCropping, let cropFreeze { return cropFreeze.with(editor.recipe.geometry) }
        let photo = GeometrySize(width: Double(source.pixelSize.width), height: Double(source.pixelSize.height))
        return CropLayout(photo: photo, geometry: editor.recipe.geometry, viewport: viewport,
                          margin: isCropping ? Self.cropMargin : 0)
    }

    /// The crop pane's writes, through the recipe so they are undo steps.
    func setGeometry(_ geometry: Geometry) {
        var recipe = editor.recipe
        recipe.geometry = geometry
        editor.setRecipe(recipe)
    }

    /// The full-size renders of the visible part (the editor's detail
    /// layers), while they are of the frames shown.
    var editedDetailPair: DisplayPair? { editor.shownDetail.map { DisplayPair($0.display) } }
    var originalDetailPair: DisplayPair? { editor.shownOriginalDetail.map { DisplayPair($0.display) } }

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
              source.id == committedSource, let shown = editor.canvasPhotoSize,
              canvas.transform.imageSize == CGSize(width: shown.width, height: shown.height),
              let visible = canvas.visibleSourceRect else { return nil }
        let transform = canvas.transform
        return CanvasViewport(visible: visible,
                              displayedWidth: Double(transform.displayedSize.width * transform.backingScale),
                              showsEdited: !isPeekingOriginal && viewMode != .original,
                              showsOriginal: isPeekingOriginal || viewMode != .edited)
    }
}
