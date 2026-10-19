import AppKit
import Foundation

/// The photo's file going missing, or being changed by someone else, while it
/// is open (parity batch 7 §3).
extension EditorModel {
    /// The file cannot be found: the canvas keeps its last frame, adjustments
    /// are recorded but not rendered, and the banner offers to locate it.
    /// Nothing else about the photo is locked.
    func enterSourceUnavailable(_ error: UserFacingError) {
        guard error.code == "source_missing", photo != nil, sourceUnavailable == nil else { return }
        sourceUnavailable = error
        setRefreshing(false)
        syncExportState()
        updateAIState()
        NoticeAnnouncement.post(AppStrings.format("source.missing.announce %@", photo?.name ?? ""), highPriority: true)
        startSourceRetry()
    }

    /// The file is back (a frame was drawn from it), or the photo went away.
    func leaveSourceUnavailable(announce: Bool) {
        guard sourceUnavailable != nil else { return }
        sourceUnavailable = nil
        stopSourceRetry()
        syncExportState()
        updateAIState()
        if announce { NoticeAnnouncement.post(AppStrings.format("source.found.announce %@", photo?.name ?? "")) }
    }

    /// Renders the current values once, to see whether the file is back.
    func retrySource() {
        guard sourceUnavailable != nil, photo != nil, document?.phase == .ready else { return }
        isRetryingSource = true
        defer { isRetryingSource = false }
        scheduleRender(force: true)
    }

    private func startSourceRetry() {
        stopSourceRetry()
        let interval = sourceRetryInterval
        sourceRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, sourceUnavailable != nil else { return }
                if appIsActive() { retrySource() }
            }
        }
        sourceActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retrySource() }
        }
    }

    func stopSourceRetry() {
        sourceRetryTask?.cancel()
        sourceRetryTask = nil
        if let observer = sourceActivationObserver { NotificationCenter.default.removeObserver(observer) }
        sourceActivationObserver = nil
    }

    /// The user chose a file for the photo whose own cannot be found. The same
    /// content is reconnected, so adjustments, undo and history stay; anything
    /// else is simply a different photo and opens as one.
    func locateSource(_ url: URL) {
        guard let photo, sourceUnavailable != nil, locateTask == nil else { return }
        let ticket = generation
        locateTask = Task { [weak self, services] in
            do {
                let relinked = try await services.relink(photo, to: url)
                guard let self, !Task.isCancelled, generation == ticket, self.photo == photo else { return }
                locateTask = nil
                self.photo = relinked
                renameDocument(relinked.name)
                retrySource()
            } catch {
                guard let self, !Task.isCancelled, generation == ticket, self.photo == photo else { return }
                locateTask = nil
                let failure = UserFacingError.service(error)
                if failure.code == "source_different" { open([url]) }
                else if failure.code != "cancelled" { publishAlert(failure) }
            }
        }
    }

    /// The file under the open photo was changed by another app: read it
    /// again from the start (the old adjustments may not fit it) and say so.
    /// An export in progress is left alone and the photo is reopened after it.
    func reopenReplacedSource(_ photo: EditorPhoto) {
        guard self.photo == photo else { return }
        if export.isInFlight { replacedAwaitingExport = photo; return }
        replacedAwaitingExport = nil
        open([photo.url], afterReplacement: photo.name)
    }

    func resumeReplacedReopen() {
        guard let waiting = replacedAwaitingExport, !export.isInFlight else { return }
        reopenReplacedSource(waiting)
    }
}
