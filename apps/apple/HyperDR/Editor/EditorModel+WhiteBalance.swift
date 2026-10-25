import CoreGraphics
import HyperDRRender
import Metal

extension EditorModel {
    func wireWhiteBalance() {
        whiteBalance.photoPoint = { [weak self] in self?.photoPoint(atCanvasPoint: $0) }
        whiteBalance.texture = { [weak self] in self?.whiteBalanceFrame?.base }
        whiteBalance.pick = { [weak self] point in
            guard let self else { throw CancellationError() }
            return try await self.editor.pickWhiteBalance(at: point)
        }
    }

    /// A point on the canvas as 0…1 on the photo it shows, from the top left;
    /// nil outside the photo and while the crop pane (which draws the photo
    /// through its box, not in the canvas's frame) is open.
    private func photoPoint(atCanvasPoint point: CGPoint) -> CGPoint? {
        guard !isCropping, let frame = canvas.imageFrame, frame.width > 0, frame.height > 0,
              frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    /// The frame the canvas draws now, whose pixels the loupe magnifies.
    private var whiteBalanceFrame: DisplayPair? {
        viewMode == .original || !hasEditedFrame ? referencePair : editedPair
    }

    /// The eyedropper can be used: a photo with a frame on the canvas, the
    /// crop pane closed and no export holding the editor.
    var canPickWhiteBalance: Bool {
        workspace == .editing && hasEditedFrame && !isCropping && !isEditingLocked
    }
}
