import HyperDRRender
import SwiftUI

/// How the system could not develop this RAW itself (iPhone, iPad Studio and
/// the export sheet). A converted DNG is still a RAW edit, so it is only
/// named; the embedded JPEG is not, so it is announced when the photo opens
/// and stays one tap away in More.
extension SourceCompatibility {
    var titleKey: LocalizedStringKey {
        switch self {
        case .convertedDNG: "ios.compat.dng.title"
        case .embeddedPreview: "ios.compat.preview.title"
        }
    }

    var messageKey: LocalizedStringKey {
        switch self {
        case .convertedDNG: "ios.compat.dng.message"
        case .embeddedPreview: "ios.compat.preview.message"
        }
    }

    /// One line for a small place (the Studio's photo facts, the export sheet).
    var lineKey: LocalizedStringKey {
        switch self {
        case .convertedDNG: "ios.compat.dng.line"
        case .embeddedPreview: "ios.compat.preview.line"
        }
    }

    var isWarning: Bool { self == .embeddedPreview }
}

/// The one line of text with its symbol, for the Studio's photo facts.
struct RAWCompatibilityLine: View {
    let compatibility: SourceCompatibility

    var body: some View {
        Label {
            Text(compatibility.lineKey)
        } icon: {
            Image(systemName: compatibility.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
        }
        .font(.caption)
        .foregroundStyle(compatibility.isWarning ? Color.hdr.warn : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The More menu's entry, which shows the explanation again.
struct RAWCompatibilityMenuItem: View {
    let editor: RecipeEditor
    @Binding var showing: Bool

    var body: some View {
        if let compatibility = editor.sourceCompatibility {
            Section {
                Button(action: { showing = true }) {
                    Label("ios.compat.menu", systemImage: compatibility.isWarning ? "exclamationmark.triangle" : "info.circle")
                }
            }
        }
    }
}

private struct RAWCompatibilityAlert: ViewModifier {
    let editor: RecipeEditor
    @Binding var showing: Bool

    /// A photo and how it was opened: a new photo with the same outcome still announces itself.
    private struct Opening: Equatable {
        var source: UUID?
        var compatibility: SourceCompatibility?
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: Opening(source: editor.source?.id, compatibility: editor.sourceCompatibility), initial: true) { _, opening in
                if opening.compatibility == .embeddedPreview { showing = true }
            }
            .alert(editor.sourceCompatibility?.titleKey ?? "", isPresented: $showing) {
                Button("ios.common.ok") {}
            } message: {
                Text(editor.sourceCompatibility?.messageKey ?? "")
            }
    }
}

extension View {
    /// Announces an opening from the RAW's embedded JPEG, and shows the
    /// explanation whenever `showing` is set.
    func rawCompatibilityAlert(editor: RecipeEditor, isPresented: Binding<Bool>) -> some View {
        modifier(RAWCompatibilityAlert(editor: editor, showing: isPresented))
    }
}
