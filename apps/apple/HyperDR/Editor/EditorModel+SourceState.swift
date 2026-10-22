import AppKit
import Foundation

/// The photo's file going missing, or being changed by someone else, while it
/// is open (parity batch 7 §3).
extension EditorModel {
    /// The file cannot be found: the canvas keeps its last frame, adjustments
    /// still render from the photo the renderer holds, export stops, and the
    /// banner offers to locate it.
    /// Nothing else about the photo is locked.
    func enterSourceUnavailable(_ error: UserFacingError) {
        guard error.code == "source_missing", photo != nil, sourceUnavailable == nil else { return }
        sourceUnavailable = error
        setRefreshing(false)
        syncExportState()
        NoticeAnnouncement.post(AppStrings.format("source.missing.announce %@", photo?.name ?? ""), highPriority: true)
        startSourceRetry()
    }

    /// The file is back (a frame was drawn from it), or the photo went away.
    func leaveSourceUnavailable(announce: Bool) {
        guard sourceUnavailable != nil else { return }
        sourceUnavailable = nil
        stopSourceRetry()
        syncExportState()
        if announce { NoticeAnnouncement.post(AppStrings.format("source.found.announce %@", photo?.name ?? "")) }
    }

    /// Checks whether the file is back. The renderer keeps the photo it
    /// opened, so the state simply ends; a render that fails again on a
    /// missing file starts it again.
    func retrySource() {
        guard sourceUnavailable != nil, let photo, document?.phase == .ready,
              FileManager.default.fileExists(atPath: photo.url.path) else { return }
        leaveSourceUnavailable(announce: true)
        refreshExportMetadata()
    }

    /// A relinked file: the editor reads it with the current recipe (the
    /// undo history survives only when the file is at the same place); the
    /// first frame from it ends the unavailable state.
    private func reopenRelinked(_ photo: EditorPhoto) {
        isRetryingSource = true
        let recipe = editor.recipe
        let editor = self.editor
        let ticket = generation
        Task { [weak self] in
            defer { self?.isRetryingSource = false }
            do {
                try await editor.open(photo.url, restoring: recipe)
                guard let self, generation == ticket, self.photo == photo else { return }
                bumpUndoRevision()
                commit(source: editor.source!)
                editorChanged()
            } catch {}
        }
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
    /// content is reconnected, so adjustments and history stay; anything
    /// else is simply a different photo and opens as one.
    func locateSource(_ url: URL) {
        guard let photo, sourceUnavailable != nil, locateTask == nil else { return }
        let ticket = generation
        isRelinking = true
        locateTask = Task { [weak self, services] in
            defer { self?.isRelinking = false }
            do {
                let relinked = try await services.relink(photo, to: url)
                guard let self, !Task.isCancelled, generation == ticket, self.photo == photo else { return }
                locateTask = nil
                self.photo = relinked
                renameDocument(relinked.name)
                reopenRelinked(relinked)
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

    /// The file under the open photo changed since the editor read it
    /// (R23-001): it is not rendered or exported until it is opened again.
    var sourceChanged: Bool {
        photo != nil && editor.sourceChanged && editor.source?.id == committedSource
    }

    /// The banner's button.
    func reopenChangedSource() {
        guard sourceChanged, let photo else { return }
        reopenReplacedSource(photo)
    }

    func resumeReplacedReopen() {
        guard let waiting = replacedAwaitingExport, !export.isInFlight else { return }
        reopenReplacedSource(waiting)
    }
}
