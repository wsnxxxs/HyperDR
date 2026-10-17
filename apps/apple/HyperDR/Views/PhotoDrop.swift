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

/// The drag-and-drop state of one canvas, across drag sessions.
///
/// The dragged files are checked while the drag is still over the window, so
/// an unsupported file shows as refused before it is released (parity G-05 /
/// O-03). Reading the URLs is asynchronous and can finish after the drag has
/// left, been dropped or been replaced by another drag; each drag is
/// therefore a session, and only the current session's check may publish a
/// state. Several files open the first openable one without comment
/// (batch 3 §12 Q12).
@MainActor @Observable final class PhotoDropCoordinator {
    /// Reads a drag's file URLs, in drag order.
    typealias Loader = @MainActor () async -> [URL]

    private(set) var state = PhotoDropState.idle

    /// Bumped by every enter, exit and drop; a check publishes only if the
    /// session it started in is still current.
    @ObservationIgnored private var session = 0
    /// Bumped by every drop; a dropped drag opens only if no later drop has
    /// been made while its URLs were read.
    @ObservationIgnored private var drop = 0

    /// A drag entered the canvas.
    func entered(model: EditorModel, load: @escaping Loader) {
        session += 1
        guard model.engine.failure == nil else { state = .rejects; return }
        state = .accepts
        let current = session
        Task {
            let urls = await load()
            guard current == session else { return }
            state = urls.contains(where: model.canOpen) ? .accepts : .rejects
        }
    }

    /// The drag left the canvas without dropping.
    func exited() {
        session += 1
        state = .idle
    }

    /// The drag was released on the canvas. Returns whether the drop is
    /// accepted: false when its files were already found unopenable.
    func dropped(model: EditorModel, load: @escaping Loader) -> Bool {
        let refused = state == .rejects
        session += 1
        state = .idle
        guard !refused else { return false }
        drop += 1
        let current = drop
        Task {
            let urls = await load()
            guard current == drop, !urls.isEmpty else { return }
            model.open(urls)
        }
        return true
    }
}

/// Feeds the canvas's drops to its `PhotoDropCoordinator`.
struct PhotoDropDelegate: DropDelegate {
    let model: EditorModel
    let coordinator: PhotoDropCoordinator

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        coordinator.entered(model: model, load: Self.loader(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: coordinator.state == .rejects ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        coordinator.exited()
    }

    func performDrop(info: DropInfo) -> Bool {
        coordinator.dropped(model: model, load: Self.loader(info))
    }

    /// Reads the providers now: they belong to this drag only.
    private static func loader(_ info: DropInfo) -> PhotoDropCoordinator.Loader {
        let providers = info.itemProviders(for: [.fileURL])
        return { await urls(from: providers) }
    }

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
