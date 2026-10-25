import CoreImage

/// CIImage headroom tagging arrived after the headroom reader. Keep the same
/// value beside materialized pixels when the system cannot attach the tag.
struct HeadroomImage {
    let image: CIImage
    let fallbackHeadroom: Float?

    init(_ image: CIImage, headroom: Float, writesImageMetadata: Bool = true) {
        if #available(macOS 26, iOS 26, *), writesImageMetadata {
            self.image = image.settingContentHeadroom(headroom)
            fallbackHeadroom = nil
        } else {
            self.image = image
            fallbackHeadroom = headroom
        }
    }
}
