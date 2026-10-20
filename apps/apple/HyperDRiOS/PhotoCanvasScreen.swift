import HyperDRDesign
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The P7-0 shell: the photo on a full-screen EDR canvas, opened from the
/// library or from Files. Entry points follow p7-adjustments §5.5: an empty
/// state with a large Choose Photo button and an Open from Files text button;
/// with a photo open, Photos leads the top bar and Open from Files sits in the
/// More menu. The adjustment controls come with P7-2.
struct PhotoCanvasScreen: View {
    /// One open request; a newer one cancels the load of the previous.
    private struct Request: Equatable {
        enum Source: Equatable { case library(PhotosPickerItem), file(URL) }
        let id = UUID()
        let source: Source
    }

    @State private var selection: PhotosPickerItem?
    @State private var request: Request?
    @State private var importingFile = false
    @State private var photo: HDRPhoto?
    @State private var loading = false
    @State private var failed = false
    @State private var headroom = HeadroomSnapshot()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                EDRCanvas(photo: photo, onHeadroom: { headroom = $0 }, onError: { _ in failed = true; photo = nil })
                    .ignoresSafeArea()
                if loading {
                    ProgressView().tint(.white)
                } else if photo == nil {
                    emptyState
                }
            }
            .safeAreaInset(edge: .bottom) { headroomReadout }
            .toolbar { if photo != nil { toolbar } }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onChange(of: selection) { _, item in
            if let item { request = Request(source: .library(item)) }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { request = Request(source: .file(url)) }
        }
        .task(id: request?.id) { await load(request?.source) }
    }

    private var emptyState: some View {
        VStack(spacing: Space.s4) {
            Text(failed ? LocalizedStringKey("ios.error.load") : LocalizedStringKey("ios.empty.message"))
                .font(.system(size: TypeScale.Size.body))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Label("ios.picker.choose", systemImage: "photo.on.rectangle")
                    .font(.system(size: TypeScale.Size.title, weight: .semibold))
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s2)
            }
            .buttonStyle(.glassProminent)
            Button("ios.file.open") { importingFile = true }
                .buttonStyle(.borderless)
                .tint(.white)
        }
        .padding(Space.s6)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Text("ios.toolbar.photos")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("ios.file.openMenu", systemImage: "folder") { importingFile = true }
            } label: {
                Label("ios.toolbar.more", systemImage: "ellipsis")
            }
        }
    }

    private var headroomReadout: some View {
        Text("ios.display.edr \(Self.headroom(headroom.current)) \(Self.headroom(headroom.potential))")
            .font(.system(size: TypeScale.Size.caption).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .padding(.bottom, Space.s2)
    }

    private static func headroom(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(1))) + "×"
    }

    /// The original bytes (`.current` keeps HEIC, DNG and gain maps as they
    /// are; a file is read inside its security scope), decoded off the main
    /// thread. The previous photo stays on screen until the new one is ready.
    private func load(_ source: Request.Source?) async {
        guard let source else { return }
        loading = true
        // A newer request has started its own load; leave its spinner alone.
        defer { if !Task.isCancelled { loading = false } }
        do {
            let loaded: HDRPhoto
            switch source {
            case .library(let item):
                guard let data = try await item.loadTransferable(type: Data.self) else { throw TemporaryHDRSource.Failure.unreadable }
                loaded = try await Task.detached(priority: .userInitiated) { try TemporaryHDRSource.load(data) }.value
            case .file(let url):
                loaded = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try TemporaryHDRSource.load(Data(contentsOf: url))
                }.value
            }
            guard !Task.isCancelled else { return }
            photo = loaded
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            photo = nil
            failed = true
        }
    }
}
