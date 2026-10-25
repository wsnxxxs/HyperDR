import CoreGraphics
import HyperDRRender
import Metal

extension EditorModel {
    func wireWhiteBalance() {
        whiteBalance.photoPoint = { [weak self] in self?.photoPoint(atCanvasPoint: $0) }
        whiteBalance.texture = { [weak self] in self?.whiteBalanceFrames.texture(at: $0) }
        whiteBalance.pick = { [weak self] point in
            guard let self else { throw CancellationError() }
            return try await self.editor.pickWhiteBalance(at: point)
        }
    }

    /// A point on the canvas as 0…1 on the photo it shows, from the top left;
    /// nil outside the photo, while the crop pane is open and while the
    /// canvas still draws the whole photo through the crop (`cropLayout`).
    private func photoPoint(atCanvasPoint point: CGPoint) -> CGPoint? {
        WhiteBalanceFrames.photoPoint(point, in: canvas.imageFrame,
                                      drawsThroughCrop: isCropping || cropLayout != nil)
    }

    /// The frames the canvas composes now, for the loupe: the original on the
    /// left of the split, the edit on the right.
    private var whiteBalanceFrames: WhiteBalanceFrames {
        let showsOriginal = !hasEditedFrame || isPeekingOriginal || viewMode == .original
        return WhiteBalanceFrames(original: referencePair?.base, edited: editedPair?.base,
                                  shown: showsOriginal ? .original : viewMode == .compare ? .compare : .edited,
                                  splitRatio: splitRatio, imageFrame: canvas.imageFrame ?? .zero)
    }

    /// The eyedropper can be used: a photo with a frame on the canvas, the
    /// crop pane closed and no export holding the editor.
    var canPickWhiteBalance: Bool {
        workspace == .editing && hasEditedFrame && !isCropping && !isEditingLocked
    }
}
