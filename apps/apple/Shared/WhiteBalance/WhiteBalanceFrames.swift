import CoreGraphics
import Metal

/// What the eyedropper's loupe magnifies and where a canvas point lands on
/// the photo, from what the canvas draws now (adjust-controls F1).
struct WhiteBalanceFrames: Equatable {
    /// How the canvas composes the two frames; the split is the compositor's:
    /// the original on its left, the edit on its right.
    enum Shown: Equatable { case original, edited, compare }
    enum Side: Equatable { case original, edited }

    var original: (any MTLTexture)?
    var edited: (any MTLTexture)?
    var shown: Shown = .edited
    var splitRatio = 0.5
    /// The photo's rectangle on the canvas, in the canvas's points.
    var imageFrame: CGRect = .zero

    static func == (a: Self, b: Self) -> Bool {
        a.original === b.original && a.edited === b.edited && a.shown == b.shown
            && a.splitRatio == b.splitRatio && a.imageFrame == b.imageFrame
    }

    /// The side drawn under a canvas point. The compositor clamps the ratio
    /// to 5…95 % and splits at the photo's width; an original that is not
    /// there leaves the edit.
    func side(at point: CGPoint) -> Side {
        guard original != nil else { return .edited }
        switch shown {
        case .original: return .original
        case .edited: return .edited
        case .compare:
            let ratio = min(0.95, max(0.05, splitRatio))
            return point.x < imageFrame.minX + imageFrame.width * ratio ? .original : .edited
        }
    }

    func texture(at point: CGPoint) -> (any MTLTexture)? {
        side(at: point) == .original ? original : edited
    }

    /// A canvas point as 0…1 on the photo, from the top left; nil outside it,
    /// and while the canvas draws the photo through the crop (the crop pane,
    /// and leaving it until the cropped frame arrives): the photo's rectangle
    /// is then not the whole photo's, and the backend would invert the crop
    /// from a point that already is on the cropped photo.
    static func photoPoint(_ point: CGPoint, in frame: CGRect?, drawsThroughCrop: Bool) -> CGPoint? {
        guard !drawsThroughCrop, let frame, frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }
}
