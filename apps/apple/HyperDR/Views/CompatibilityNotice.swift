import HyperDRDesign
import HyperDRRender
import SwiftUI

/// What the inspector and the export panel say when macOS could not develop
/// the RAW itself. A converted DNG is still a RAW edit, so it gets a quiet
/// note; the embedded JPEG is not, so it gets a warning wherever the user
/// could mistake the result for a RAW development.
///
/// LibRaw chosen in Settings gets its own note: the camera is supported, the
/// conversion was the user's choice. When LibRaw could not read the camera,
/// the note says Apple's decoder developed it instead.
struct CompatibilityNotice: View {
    enum Place { case inspector, export }

    let compatibility: SourceCompatibility?
    /// The open photo, for the inspector's LibRaw notes.
    var source: EditorSource? = nil
    var place = Place.inspector

    var body: some View {
        switch compatibility {
        case .none:
            if place == .inspector, let fallback = source?.rawDecoderFallback,
               fallback.requested == RAWDecoderFallback.libRAW {
                note(Text("mac.compat.libraw.declined \(fallback.used)"), style: .info)
            }
        case .convertedDNG:
            if place == .inspector {
                note(Text(source?.rawCompatibilityByChoice == true ? "mac.compat.libraw.note" : "mac.compat.dng.note"),
                     style: .info)
            }
        case .embeddedPreview:
            switch place {
            case .inspector:
                note(Text("mac.compat.preview.warning"), style: .warning)
            case .export:
                InspectorNotice(Text("mac.compat.preview.export"), style: .warning)
            }
        }
    }

    @ViewBuilder private func note(_ text: Text, style: InspectorNotice.Style) -> some View {
        InspectorNotice(text, style: style)
            .padding(.horizontal, Layout.panelPadding)
            .padding(.vertical, Space.s3)
        Divider()
    }
}
