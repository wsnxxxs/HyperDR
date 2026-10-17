import SwiftUI
import UniformTypeIdentifiers

/// What a drag over the canvas would do if released here.
enum PhotoDropState: Equatable {
    case idle
    /// At least one dragged file can be opened (or the files are still being
    /// read; an unopenable drop is then refused by the model's own alert).
    case accepts
    /// None of the dragged files can be opened, or the engine is down.
    case rejects
}

/// Accepts file URLs dropped on the canvas. The files are checked while the
/// drag is still over the window, so an unsupported file shows as refused
/// before it is released (parity G-05 / O-03). Several files open the first
/// openable one without comment (batch 3 §12 Q12).
struct PhotoDropDelegate: DropDelegate {
    let model: EditorModel
    @Binding var state: PhotoDropState

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard model.engine.failure == nil else { state = .rejects; return }
        state = .accepts
        let providers = info.itemProviders(for: [.fileURL])
        let model = model, state = $state
        Task {
            let urls = await Self.urls(from: providers)
            // The drag may have left, or been dropped, while the URLs loaded.
            guard state.wrappedValue != .idle else { return }
            state.wrappedValue = urls.contains(where: model.canOpen) ? .accepts : .rejects
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: state == .rejects ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        state = .idle
    }

    func performDrop(info: DropInfo) -> Bool {
        let refused = state == .rejects
        state = .idle
        guard !refused else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        let model = model
        Task {
            let urls = await Self.urls(from: providers)
            if !urls.isEmpty { model.open(urls) }
        }
        return true
    }

    /// The dropped file URLs, in drag order.
    private static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}
