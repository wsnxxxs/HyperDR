import HyperDRDesign
import SwiftUI

/// The left of the iPad's export page (ipad-studio §5): the photo as the
/// export will carry it, on its frame when the frame is on, drawn live on an
/// EDR canvas of its own, so its highlights show as the file will. It follows
/// the export's frame switch, and is only a picture: nothing on it takes a touch.
struct PadExportPreview: View {
    let session: EditingSession
    let editor: RecipeEditor

    var body: some View {
        ZStack {
            Color.black
            if let content {
                Group {
                    if session.frame.isEnabled, let layout = session.frameLayout {
                        FramedPhoto(layout: layout, settings: session.frame, caption: session.caption(for: layout)) {
                            canvas(content)
                        }
                    } else {
                        canvas(content)
                    }
                }
                .padding(36)
                .transition(.opacity)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .overlay(alignment: .topLeading) {
            if let name = session.photoName {
                Text(verbatim: name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Space.s4)
                    .padding(.top, Space.s3)
            }
        }
        .animation(.smooth(duration: 0.3), value: session.frame)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func canvas(_ content: EDRCanvasUIView.Content) -> some View {
        EDRCanvas(content: content, onHeadroom: { _ in }, onDrawableSize: { _ in }, onHoldOriginal: { _ in },
                  onError: { _ in }, onTransform: { _ in })
    }

    /// The edited photo as rendered now, at the size of its last frame.
    private var content: EDRCanvasUIView.Content? {
        guard let frame = editor.frame, let source = editor.frameSource else { return nil }
        let size = frame.request.recipe.geometry.outputSize(of: source.pixelSize)
        return EDRCanvasUIView.Content(edited: DisplayPair(frame.display), previewsAsSDR: editor.previewsAsSDR,
                                       imageSize: CGSize(width: size.width, height: size.height))
    }
}
