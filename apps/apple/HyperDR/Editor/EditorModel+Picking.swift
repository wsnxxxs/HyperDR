import CoreGraphics

extension EditorModel {
    /// The curve eyedropper's mapping from the canvas to the photo and its
    /// editor; the white balance's twin.
    func wireTargetPickers() {
        curvePick.attach(editor)
        curvePick.picker.photoPoint = { [weak self] in self?.pickablePhotoPoint($0) }
        whiteBalance.onBegin = { [weak self] in self?.curvePick.picker.reset() }
        curvePick.picker.onActivate = { [weak self] in self?.whiteBalance.reset() }
    }

    /// A point on the canvas as 0…1 on the photo, while an eyedropper can use it.
    private func pickablePhotoPoint(_ point: CGPoint) -> CGPoint? {
        guard canPickWhiteBalance else { return nil }
        return WhiteBalanceFrames.photoPoint(point, in: canvas.imageFrame, drawsThroughCrop: isCropping || cropLayout != nil)
    }

    /// Ends every drag eyedropper: another photo, the crop pane, a locked editor.
    func resetTargetPickers() {
        curvePick.picker.reset()
    }
}
