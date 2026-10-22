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
///
/// A file whose URL cannot be read may be a photograph that would open, so:
/// an openable URL among the others opens as usual; without one, a read
/// error keeps the drag accepted and the drop reports that error through the
/// model; only a drag read in full and found unopenable is refused.
@MainActor @Observable final class PhotoDropCoordinator {
    /// Reads a drag's file URLs, in drag order.
    typealias Loader = @MainActor () async -> PhotoDropFiles

    private(set) var state = PhotoDropState.idle
    /// The name of the first openable dragged file, once the drag has been
    /// read; the canvas names it while an export is running.
    private(set) var firstName: String?

    /// Bumped by every enter, exit and drop; a check publishes only if the
    /// session it started in is still current.
    @ObservationIgnored private var session = 0
    /// Bumped by every accepted drop; a dropped drag opens only if no later
    /// drop has been accepted while its URLs were read. A refused drop leaves
    /// an earlier accepted one to open.
    @ObservationIgnored private var drop = 0

    /// A drag entered the canvas.
    func entered(model: EditorModel, load: @escaping Loader) {
        session += 1
        guard model.engine.failure == nil else { state = .rejects; return }
        state = .accepts
        let current = session
        Task {
            let files = await load()
            guard current == session else { return }
            state = files.urls.contains(where: model.canOpen) || files.firstError != nil ? .accepts : .rejects
            firstName = files.urls.first(where: model.canOpen)?.lastPathComponent
        }
    }

    /// The drag left the canvas without dropping.
    func exited() {
        session += 1
        state = .idle
        firstName = nil
    }

    /// The drag was released on the canvas. Returns whether the drop is
    /// accepted: false when its files were already found unopenable.
    func dropped(model: EditorModel, load: @escaping Loader) -> Bool {
        let refused = state == .rejects
        session += 1
        state = .idle
        firstName = nil
        guard !refused else { return false }
        drop += 1
        let current = drop
        Task {
            let files = await load()
            guard current == drop else { return }
            if let error = files.firstError, !files.urls.contains(where: model.canOpen) {
                model.report(openFailure: error)
            } else if !files.urls.isEmpty {
                // Opens the first openable URL, or alerts that none is.
                model.open(files.urls)
            }
        }
        return true
    }
}

/// What reading a drag's providers gave: the URLs read, in drag order, and
/// the first error of those that could not be read.
struct PhotoDropFiles: Sendable {
    var urls: [URL] = []
    var firstError: (any Error)? = nil
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

    static func urls(from providers: [NSItemProvider]) async -> PhotoDropFiles {
        var results: [Result<URL, any Error>] = []
        for provider in providers {
            let result = await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<URL, any Error>?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    continuation.resume(returning: url.map { .success($0) } ?? error.map { .failure($0) })
                }
            }
            if let result { results.append(result) }
        }
        return collect(results)
    }

    /// The URLs that were read, in order, and the first error. Keeping both
    /// lets the coordinator tell an unreadable photograph from a drag that is
    /// simply unsupported.
    static func collect(_ results: [Result<URL, any Error>]) -> PhotoDropFiles {
        var files = PhotoDropFiles()
        for result in results {
            switch result {
            case .success(let url): files.urls.append(url)
            case .failure(let error): files.firstError = files.firstError ?? error
            }
        }
        return files
    }
}
