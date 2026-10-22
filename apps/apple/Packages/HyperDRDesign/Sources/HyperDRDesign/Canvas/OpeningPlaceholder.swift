import CoreGraphics
import SwiftUI

/// The photo's embedded thumbnail while it opens, in the canvas's place
/// until the first frame: fitted to the full photo's proportions (the
/// thumbnail's own can differ slightly, so it fills that rectangle and is
/// clipped), softened and dimmed a little so it does not read as the edit.
/// SDR and for display only; the Mac canvas and the iOS editor share it.
///
/// It keeps the last image it was given, so when the host's placeholder
/// goes (first frame, failure, close) it fades out instead of vanishing.
public struct OpeningPlaceholder: View {
    /// What to show; nil fades the shown one out.
    public struct Content: Equatable {
        public let id: UUID
        public let image: CGImage
        /// The oriented full photo, in pixels.
        public let pixelSize: CGSize

        public init(id: UUID, image: CGImage, pixelSize: CGSize) {
            self.id = id
            self.image = image
            self.pixelSize = pixelSize
        }

        public static func == (lhs: Content, rhs: Content) -> Bool {
            lhs.id == rhs.id && lhs.image === rhs.image && lhs.pixelSize == rhs.pixelSize
        }
    }

    private let content: Content?
    /// Cover what is behind the photo's rectangle too (an earlier photo).
    private let backdrop: Bool
    @State private var shown: Content?

    public init(_ content: Content?, backdrop: Bool = false) {
        self.content = content
        self.backdrop = backdrop
    }

    public var body: some View {
        ZStack {
            if let shown {
                ZStack {
                    if backdrop { Color.black }
                    Color.clear
                        .aspectRatio(Self.ratio(shown), contentMode: .fit)
                        .overlay {
                            Image(decorative: shown.image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .blur(radius: 3, opaque: true)
                        .brightness(-0.08)
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { shown = content }
        .onChange(of: content) { _, new in
            if let new {
                withAnimation(shown == nil ? .smooth(duration: 0.2) : nil) { shown = new }
            } else {
                withAnimation(.smooth(duration: 0.25)) { shown = nil }
            }
        }
    }

    private static func ratio(_ content: Content) -> CGFloat {
        let size = content.pixelSize.width > 0 && content.pixelSize.height > 0
            ? content.pixelSize : CGSize(width: content.image.width, height: content.image.height)
        return size.width / max(size.height, 1)
    }
}
