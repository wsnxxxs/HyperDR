import HyperDRDesign
import SwiftUI
import UniformTypeIdentifiers

/// The choices of a caption typeface: the system's designs, then the families
/// the system ships and the fonts imported into `FrameFontLibrary`. A family
/// chosen elsewhere and missing here stays listed, marked as missing.
struct FrameTypefaceChoices: View {
    @Binding var selection: FrameTypeface

    var body: some View {
        let offered = FrameFontLibrary.shared.offeredFamilies()
        Picker(selection: $selection) {
            ForEach(FrameTypeface.designs) { face in
                face.title.tag(face)
            }
            Divider()
            ForEach(offered, id: \.self) { family in
                Text(verbatim: family).font(.custom(family, size: 17)).tag(FrameTypeface.family(family))
            }
            if let family = selection.familyName, !offered.contains(family) {
                Text("ios.frame.font.unavailable \(family)").tag(selection)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
    }
}

/// Imports a font file and sets the caption's lines in it.
struct FrameFontImport: ViewModifier {
    @Binding var settings: FrameSettings
    @Binding var isPresented: Bool
    @Binding var failed: Bool

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.font],
                             allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                settings.textFace = .family(try FrameFontLibrary.shared.importFont(from: url))
                failed = false
            } catch {
                failed = true
            }
        }
    }
}

extension FrameSettings {
    /// Removes an imported font; a typeface set in it goes back to its default.
    mutating func removeFont(_ entry: FrameFontLibrary.Entry) {
        if entry.families.contains(textFace.familyName ?? "") { textFace = .system }
        if entry.families.contains(signatureFace.familyName ?? "") { signatureFace = .serif }
        FrameFontLibrary.shared.remove(entry)
    }
}

/// The typefaces as a form section, in the iPhone's caption sheet.
struct FrameTypefaceSection: View {
    @Binding var settings: FrameSettings
    @State private var importing = false
    @State private var importFailed = false

    var body: some View {
        Section {
            NavigationLink {
                FrameTypefaceList(selection: $settings.textFace, title: Text("ios.frame.font.text"))
            } label: {
                LabeledContent { settings.textFace.title } label: { Text("ios.frame.font.text") }
            }
            NavigationLink {
                FrameTypefaceList(selection: $settings.signatureFace, title: Text("ios.frame.font.signature"))
            } label: {
                LabeledContent { settings.signatureFace.title } label: { Text("ios.frame.font.signature") }
            }
            Button("ios.frame.font.import", systemImage: "textformat") { importing = true }
            ForEach(FrameFontLibrary.shared.entries) { entry in
                Text(verbatim: entry.families.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .swipeActions {
                        Button("ios.frame.font.remove", systemImage: "trash", role: .destructive) {
                            settings.removeFont(entry)
                        }
                    }
            }
        } header: {
            Text("ios.frame.font")
        } footer: {
            if importFailed {
                Text("ios.frame.font.importFailed").foregroundStyle(Color.hdr.warn)
            }
        }
        .modifier(FrameFontImport(settings: $settings, isPresented: $importing, failed: $importFailed))
    }
}

/// One typeface's choices on a page of its own.
private struct FrameTypefaceList: View {
    @Binding var selection: FrameTypeface
    let title: Text

    var body: some View {
        Form { FrameTypefaceChoices(selection: $selection) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The typefaces as rows of the iPad Studio's Frame tool.
struct PadFrameTypefaceRows: View {
    @Binding var settings: FrameSettings
    @State private var importing = false
    @State private var importFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: PadMetrics.rowSpacing) {
            PadMenuRow(title: Text("ios.frame.font.text"), value: settings.textFace.title) {
                FrameTypefaceChoices(selection: $settings.textFace)
            }
            PadMenuRow(title: Text("ios.frame.font.signature"), value: settings.signatureFace.title) {
                FrameTypefaceChoices(selection: $settings.signatureFace)
            }
            HStack(spacing: PadMetrics.rowSpacing) {
                PadActionTile(title: Text("ios.frame.font.import"), symbol: "textformat") { importing = true }
                if !FrameFontLibrary.shared.entries.isEmpty {
                    Menu {
                        ForEach(FrameFontLibrary.shared.entries) { entry in
                            Button(role: .destructive) { settings.removeFont(entry) } label: {
                                Text("ios.frame.font.removeNamed \(entry.families.joined(separator: ", "))")
                            }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "trash").font(.system(size: 17, weight: .medium))
                            Text("ios.frame.font.remove").font(.caption.weight(.medium)).lineLimit(1)
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .padRow()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            if importFailed {
                PadNote(text: Text("ios.frame.font.importFailed"), symbol: "exclamationmark.triangle", tint: Color.hdr.warn)
            }
        }
        .modifier(FrameFontImport(settings: $settings, isPresented: $importing, failed: $importFailed))
    }
}

extension FrameTypeface {
    var title: Text {
        switch self {
        case .system: Text("ios.frame.font.system")
        case .serif: Text("ios.frame.font.serif")
        case .rounded: Text("ios.frame.font.rounded")
        case .monospaced: Text("ios.frame.font.monospaced")
        // A family missing here says so in its own name, not in a sentence.
        case .family(let name):
            isAvailable ? Text(verbatim: name) : Text("ios.frame.font.unavailable \(name)").foregroundStyle(Color.hdr.warn)
        }
    }
}
