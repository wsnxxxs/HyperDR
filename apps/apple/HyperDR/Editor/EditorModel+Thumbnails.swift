import CoreGraphics
import Foundation
import HyperDREngine

extension EditorModel {
    /// The export sheet owns this task. Cancellation stops summary work without
    /// affecting the frozen export or history. Multiple owners can overlap.
    func trackExportSummaryThumbnail() async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        thumbnailTrackers.insert(id)
        updateSummaryThumbnail()
        defer {
            thumbnailTrackers.remove(id)
            if thumbnailTrackers.isEmpty {
                summaryThumbnailTask?.cancel(); summaryThumbnailTask = nil
                summaryThumbnailTicket &+= 1; summaryThumbnailFrame = nil
            }
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(86_400)) } catch { break }
        }
    }

    func thumbnailFrameDidChange() {
        if !thumbnailTrackers.isEmpty { updateSummaryThumbnail() }
        else if photo == nil { exportSummaryThumbnail = .unavailable }
        fillDeferredExportThumbnail()
    }

    private func updateSummaryThumbnail() {
        summaryThumbnailTask?.cancel(); summaryThumbnailTicket &+= 1
        guard photo != nil else { exportSummaryThumbnail = .unavailable; return }
        guard document?.previewError == nil else { exportSummaryThumbnail = .unavailable; return }
        guard let frame = currentEditedFrame else { exportSummaryThumbnail = .loading; return }
        let ticket = summaryThumbnailTicket, epoch = thumbnailEpoch
        let deadline = summaryThumbnailLastStart.map { $0 + .milliseconds(200) }
        summaryThumbnailTask = Task { [weak self, services] in
            if let deadline { do { try await ContinuousClock().sleep(until: deadline) } catch { return } }
            guard let self, !Task.isCancelled, thumbnailEpoch == epoch else { return }
            summaryThumbnailLastStart = .now
            let image = await services.sdrThumbnail(of: frame, maxPixelSize: 344)
            guard !Task.isCancelled, thumbnailEpoch == epoch, summaryThumbnailTicket == ticket,
                  !thumbnailTrackers.isEmpty else { return }
            exportSummaryThumbnail = image.map(ThumbnailState.ready) ?? .unavailable
            summaryThumbnailFrame = image == nil ? nil : frame
        }
    }

    func frozenExportThumbnailFrame() -> PreviewFrame? {
        guard document?.previewError == nil else { return nil }
        if case .ready = exportSummaryThumbnail { return summaryThumbnailFrame ?? currentEditedFrame }
        // Fixed-folder exports need no sheet, so there may be no summary owner.
        return thumbnailTrackers.isEmpty ? currentEditedFrame : nil
    }

    /// A missing frame at admission can fill progress/result in memory later;
    /// it never backfills a retained record whose admission payload was nil.
    func fillDeferredExportThumbnail() {
        guard exportThumbnailNeedsDeferred, export.thumbnail == .loading, deferredExportThumbnailTask == nil,
              export.isInFlight || export.phase == .succeeded else { return }
        guard exportThumbnailEditGeneration == editGeneration, document?.previewError == nil else {
            export.thumbnail = .unavailable; return
        }
        guard let frame = currentEditedFrame else { return }
        let epoch = thumbnailEpoch, revision = exportThumbnailEditGeneration
        deferredExportThumbnailTask = Task { [weak self, services] in
            let image = await services.sdrThumbnail(of: frame, maxPixelSize: 256)
            guard let self, !Task.isCancelled, thumbnailEpoch == epoch else { return }
            deferredExportThumbnailTask = nil
            guard export.thumbnail == .loading, exportThumbnailEditGeneration == revision,
                  editGeneration == revision else { return }
            exportThumbnailNeedsDeferred = false
            export.thumbnail = image.map(ThumbnailState.ready) ?? .unavailable
        }
    }

    func versionThumbnail(_ id: String) -> ThumbnailState {
        if let value = versionThumbnails[id] {
            versionThumbnailOrder.removeAll { $0 == id }; versionThumbnailOrder.append(id)
            return value
        }
        guard let photo, exportVersions.contains(where: { $0.id == id }) else { return .unavailable }
        cacheVersionThumbnail(.loading, id: id)
        versionThumbnailQueue.append(id)
        if versionThumbnailTask == nil {
            let epoch = thumbnailEpoch
            versionThumbnailTask = Task(priority: .utility) { [weak self, services] in
                guard let self else { return }
                defer { if thumbnailEpoch == epoch { versionThumbnailTask = nil } }
                while !Task.isCancelled, thumbnailEpoch == epoch, !versionThumbnailQueue.isEmpty {
                    let next = versionThumbnailQueue.removeFirst()
                    let image = await services.exportThumbnail(photo, version: next)
                    guard !Task.isCancelled, thumbnailEpoch == epoch, self.photo == photo else { return }
                    guard versionThumbnails[next] != nil else { continue }
                    let value = image.map(ThumbnailState.ready) ?? .unavailable
                    cacheVersionThumbnail(value, id: next)
                    if export.result?.export == next, !export.isInFlight { export.thumbnail = value }
                }
            }
        }
        return .loading
    }

    func cacheVersionThumbnail(_ value: ThumbnailState, id: String) {
        versionThumbnails[id] = value
        versionThumbnailOrder.removeAll { $0 == id }; versionThumbnailOrder.append(id)
        while versionThumbnailOrder.count > 20 {
            let oldest = versionThumbnailOrder.removeFirst()
            versionThumbnails[oldest] = nil
            versionThumbnailQueue.removeAll { $0 == oldest }
        }
    }

    func resetThumbnailsForPhotoSwitch() {
        thumbnailEpoch &+= 1; summaryThumbnailTicket &+= 1
        summaryThumbnailTask?.cancel(); deferredExportThumbnailTask?.cancel(); versionThumbnailTask?.cancel()
        summaryThumbnailTask = nil; deferredExportThumbnailTask = nil; versionThumbnailTask = nil
        summaryThumbnailFrame = nil; summaryThumbnailLastStart = nil
        exportThumbnailEditGeneration = nil; exportThumbnailPersisted = false; exportThumbnailNeedsDeferred = false
        versionThumbnailQueue = []; versionThumbnailOrder = []; versionThumbnails = [:]
        exportSummaryThumbnail = .loading
    }
}
