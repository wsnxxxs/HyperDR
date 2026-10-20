import HyperDRDesign
import PhotosUI
import SwiftUI

/// The P7-0 shell: one button that picks a photo from the library, and the
/// photo on a full-screen EDR canvas. The real editor follows the design.
struct PhotoCanvasScreen: View {
    @State private var selection: PhotosPickerItem?
    @State private var photo: HDRPhoto?
    @State private var loading = false
    @State private var failed = false
    @State private var headroom = HeadroomSnapshot()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EDRCanvas(photo: photo, onHeadroom: { headroom = $0 }, onError: { _ in failed = true; photo = nil })
                .ignoresSafeArea()
            if loading {
                ProgressView().tint(.white)
            } else if photo == nil {
                ContentUnavailableView {
                    Label("ios.empty.title", systemImage: "photo.on.rectangle")
                } description: {
                    Text(failed ? LocalizedStringKey("ios.error.load") : LocalizedStringKey("ios.empty.message"))
                }
                .foregroundStyle(.white)
            }
        }
        .safeAreaInset(edge: .bottom) { controls }
        .task(id: selection) { await load(selection) }
    }

    private var controls: some View {
        VStack(spacing: Space.s2) {
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Label("ios.picker.choose", systemImage: "photo")
            }
            .buttonStyle(.glassProminent)
            Text("ios.display.edr \(Self.headroom(headroom.current)) \(Self.headroom(headroom.potential))")
                .font(.system(size: TypeScale.Size.caption).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.bottom, Space.s2)
    }

    private static func headroom(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(1))) + "×"
    }

    /// The original bytes (`.current` keeps HEIC, DNG and gain maps as they
    /// are), decoded off the main thread.
    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loading = true
        // A newer selection has started its own load; leave its spinner alone.
        defer { if !Task.isCancelled { loading = false } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw TemporaryHDRSource.Failure.unreadable }
            let loaded = try await Task.detached(priority: .userInitiated) { try TemporaryHDRSource.load(data) }.value
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
