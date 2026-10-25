import CoreGraphics

extension EditorModel {
    /// The curve eyedropper's mapping from the canvas to the photo and its
    /// editor; the white balance's twin.
    func wireTargetPickers() {
        curvePick.attach(editor)
        mixerPick.attach(editor)
        for picker in [curvePick.picker, mixerPick.picker] {
            picker.photoPoint = { [weak self] in self?.pickablePhotoPoint($0) }
            picker.onActivate = { [weak self] in
                guard let self else { return }
                self.whiteBalance.reset()
                for other in self.targetPickers where other !== picker { other.reset() }
            }
        }
        whiteBalance.onBegin = { [weak self] in self?.resetTargetPickers() }
    }

    /// A point on the canvas as 0…1 on the photo, while an eyedropper can use it.
    private func pickablePhotoPoint(_ point: CGPoint) -> CGPoint? {
        guard canPickWhiteBalance else { return nil }
        return WhiteBalanceFrames.photoPoint(point, in: canvas.imageFrame, drawsThroughCrop: isCropping || cropLayout != nil)
    }

    /// Ends every drag eyedropper: another photo, the crop pane, a locked editor.
    func resetTargetPickers() {
        for picker in targetPickers { picker.reset() }
    }

    var targetPickers: [TargetPicker] { [curvePick.picker, mixerPick.picker] }
}
