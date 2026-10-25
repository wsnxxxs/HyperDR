import HyperDRDesign
import HyperDRRender
import SwiftUI

/// What the inspector and the export panel say when macOS could not develop
/// the RAW itself. A converted DNG is still a RAW edit, so it gets a quiet
/// note; the embedded JPEG is not, so it gets a warning wherever the user
/// could mistake the result for a RAW development.
struct CompatibilityNotice: View {
    enum Place { case inspector, export }

    let compatibility: SourceCompatibility?
    var place = Place.inspector

    var body: some View {
        switch compatibility {
        case .none:
            EmptyView()
        case .convertedDNG:
            if place == .inspector {
                InspectorNotice(Text("mac.compat.dng.note"), style: .info)
                    .padding(.horizontal, Layout.panelPadding)
                    .padding(.vertical, Space.s3)
                Divider()
            }
        case .embeddedPreview:
            switch place {
            case .inspector:
                InspectorNotice(Text("mac.compat.preview.warning"), style: .warning)
                    .padding(.horizontal, Layout.panelPadding)
                    .padding(.vertical, Space.s3)
                Divider()
            case .export:
                InspectorNotice(Text("mac.compat.preview.export"), style: .warning)
            }
        }
    }
}
