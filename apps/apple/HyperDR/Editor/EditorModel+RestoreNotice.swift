import Foundation

/// What the canvas says about the photo remembered from the last launch.
enum RestoreNotice: Equatable {
    /// The photo is open again; adjustments are not kept. `hasHistory` is
    /// whether the export history has versions to restore settings from.
    case reopened(hasHistory: Bool)
    /// The remembered photo cannot be found; `name` is what it was called.
    case missing(name: String?)
}

extension EditorModel {
    /// What the chip at the canvas's foot says, if anything.
    var canvasNotice: CanvasNotice? {
        if case .reopened(let hasHistory) = restoreNotice { return .restored(hasHistory: hasHistory) }
        if let sourceReplacedNotice { return .sourceReplaced(name: sourceReplacedNotice) }
        return nil
    }

    /// The first frame is in: say so once the history is known (or after one
    /// second), so the sentence is right when it appears.
    func armRestoreNotice() {
        restoreNotice = nil
        restoreNoticePending = true
        restoreNoticeTask?.cancel()
        let clock = services.openClock
        let deadline = clock.now + .seconds(1)
        restoreNoticeTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            self?.showRestoreNoticeIfPending()
        }
    }

    func showRestoreNoticeIfPending() {
        guard restoreNoticePending, photo != nil else { return }
        restoreNoticePending = false
        restoreNoticeTask?.cancel()
        restoreNotice = .reopened(hasHistory: !exportVersions.isEmpty)
    }

    /// Nothing said about the last launch any more: an edit, a new photo, an
    /// export, or the user closed it.
    func clearRestoreNotice() {
        restoreNoticePending = false
        restoreNoticeTask?.cancel()
        restoreNoticeTask = nil
        if restoreNotice != nil { restoreNotice = nil }
        if sourceReplacedNotice != nil { sourceReplacedNotice = nil }
    }

    func dismissRestoreNotice() { clearRestoreNotice() }
}
