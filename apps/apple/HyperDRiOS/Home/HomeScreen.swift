import HyperDRDesign
import PhotosUI
import SwiftUI

/// The first screen: the system photo library, embedded. HyperDR has no
/// library of its own; it browses the user's through `PhotosPicker`, which
/// runs out of process and needs no access to the library. One tap opens a
/// photo in the editor. Files and the LUT library sit in the header, and on
/// iPad a photo can be dropped onto the screen from Photos or Files.
///
/// The header is laid out above the picker, not as a navigation toolbar: a
/// toolbar lets the content run under the bar, and the picker's remote view
/// would then take the bar's touches (on iPad in landscape it took them all).
struct HomeScreen: View {
    let session: EditingSession
    @State private var selection: PhotosPickerItem?
    @State private var importingFile = false
    @State private var showingLUTs = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if session.isAvailable {
                    library
                } else {
                    ContentUnavailableView {
                        Label("ios.home.unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("ios.home.unavailable.detail")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: selection) { _, item in
            // Cleared once used, so picking the same photo again (after a
            // failed load, or after closing it) is a new request too.
            guard let item else { return }
            selection = nil
            session.open(.library(item))
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { session.open(.file(url)) }
        }
        .sheet(isPresented: $showingLUTs) {
            if let editor = session.editor { LUTLibrarySheet(library: session.exports.luts, editor: editor) }
        }
        .alert(Text("ios.error.load"), isPresented: Binding(get: { session.openFailed }, set: { session.openFailed = $0 })) {
            Button("ios.common.ok", role: .cancel) {}
        }
    }

    private var library: some View {
        PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
            EmptyView()
        }
        .photosPickerStyle(.inline)
        .photosPickerDisabledCapabilities([.selectionActions])
        .photosPickerAccessoryVisibility(.hidden, edges: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .dropDestination(for: ImportedPhoto.self) { photos, _ in
            guard let photo = photos.first else { return false }
            session.open(.imported(photo))
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Color.hdr.accent, lineWidth: 3)
                    .padding(Space.s3)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        // Both buttons trail: the leading corner is where iPadOS puts a
        // windowed app's window controls.
        ZStack {
            Text(verbatim: "HyperDR")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            GlassEffectContainer(spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Spacer(minLength: 0)
                    headerButton("ios.lut.title", systemImage: "camera.filters") { showingLUTs = true }
                    headerButton("ios.file.open", systemImage: "folder") { importingFile = true }
                }
            }
        }
        .padding(.horizontal, Space.s4)
        .frame(height: 56)
    }

    private func headerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(!session.isAvailable)
    }
}
