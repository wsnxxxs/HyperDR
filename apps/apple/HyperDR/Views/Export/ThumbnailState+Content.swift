import CoreGraphics
import HyperDRDesign
import SwiftUI

extension ThumbnailState {
    /// What the design package's box draws for this state. `showsSpinner` is
    /// for the export panel's summary only (a loading box elsewhere stays
    /// still); the picture keeps its proportions so the box can fit it whole.
    func content(showsSpinner: Bool = false) -> ThumbnailContent {
        switch self {
        case .loading:
            .loading(showsSpinner: showsSpinner)
        case .unavailable:
            .unavailable
        case .ready(let image):
            image.width > 0 && image.height > 0
                ? .image(Image(decorative: image, scale: 2), aspectRatio: CGFloat(image.width) / CGFloat(image.height))
                : .unavailable
        }
    }
}
