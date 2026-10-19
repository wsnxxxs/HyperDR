import SwiftUI

/// What a thumbnail box shows. The picture is always the whole photograph
/// (never cropped); the model decides which state it is in, the box only
/// draws it.
public enum ThumbnailContent {
    /// The picture is on its way: an empty box with no icon. `showsSpinner`
    /// (the export panel's summary only) adds a small spinner once the wait
    /// has gone past half a second.
    case loading(showsSpinner: Bool = false)
    /// The picture, with its width over height, which decides how it fits.
    case image(Image, aspectRatio: CGFloat)
    /// There is none (it could not be made, or the record predates them): a
    /// quiet placeholder, no message.
    case unavailable
}

/// How a picture of a given proportion sits in a thumbnail box.
struct ThumbnailFit: Equatable {
    /// The picture's size inside the box.
    var size: CGSize
    /// The picture fills the box (to within 1 %), so it needs no edge line.
    var fills: Bool

    init(aspectRatio: CGFloat, in box: CGSize) {
        guard aspectRatio > 0, box.width > 0, box.height > 0 else {
            size = box; fills = true; return
        }
        let boxRatio = box.width / box.height
        if abs(aspectRatio / boxRatio - 1) < 0.01 {
            size = box; fills = true
        } else if aspectRatio > boxRatio {
            size = CGSize(width: box.width, height: box.width / aspectRatio); fills = false
        } else {
            size = CGSize(width: box.height * aspectRatio, height: box.height); fills = false
        }
    }
}

/// A photo's thumbnail: a box on the sunken surface with the whole picture
/// fitted inside it. When the picture does not fill the box a 0.5 pt hairline
/// marks its edge, so a white or black frame stays visible on the same
/// colour. The picture never changes with the appearance; only the box and
/// its outline do. It is decoration for VoiceOver.
public struct Thumbnail: View {
    private let content: ThumbnailContent
    private let width: CGFloat
    private let height: CGFloat
    /// How long a loading box waits before its spinner shows.
    var spinnerDelay: Duration = .milliseconds(500)

    public init(_ content: ThumbnailContent, width: CGFloat, height: CGFloat) {
        self.content = content
        self.width = width
        self.height = height
    }

    /// A picture that fills the box, or the placeholder without one.
    public init(image: Image?, width: CGFloat, height: CGFloat) {
        self.init(image.map { .image($0, aspectRatio: width / height) } ?? .unavailable, width: width, height: height)
    }

    public var body: some View {
        ZStack {
            Color.hdr.surfaceSunken
            switch content {
            case .image(let image, let aspectRatio):
                let fit = ThumbnailFit(aspectRatio: aspectRatio, in: CGSize(width: width, height: height))
                image.resizable().interpolation(.high).frame(width: fit.size.width, height: fit.size.height)
                    .overlay { if !fit.fills { Rectangle().strokeBorder(Color.hdr.line, lineWidth: 0.5) } }
            case .loading(let showsSpinner):
                if showsSpinner { DelayedSpinner(delay: spinnerDelay) }
            case .unavailable:
                Image(systemName: "photo").font(.system(size: min(width, height) / 3))
                    .foregroundStyle(Color.hdr.inkDisabled)
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: Radius.sm))
        .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.hdr.line) }
        .accessibilityHidden(true)
    }

    func spinnerDelay(_ delay: Duration) -> Thumbnail {
        var copy = self
        copy.spinnerDelay = delay
        return copy
    }
}

/// When a loading box shows its spinner: once `delay` has passed, unless the
/// wait is cancelled first (the picture arrived, the box went away).
@MainActor @Observable final class SpinnerGate {
    private(set) var isShown = false

    func wait(_ delay: Duration) async {
        guard !isShown else { return }
        try? await Task.sleep(for: delay)
        if !Task.isCancelled { isShown = true }
    }
}

/// A small spinner that only appears once `delay` has passed.
private struct DelayedSpinner: View {
    let delay: Duration
    @State private var gate = SpinnerGate()

    var body: some View {
        Group {
            if gate.isShown { ProgressView().controlSize(.small) }
        }
        .task { await gate.wait(delay) }
    }
}
