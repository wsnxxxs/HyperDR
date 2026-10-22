import CoreGraphics
import Foundation
import HyperDRRender

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

    func updateSummaryThumbnail() {
        summaryThumbnailTask?.cancel(); summaryThumbnailTicket &+= 1
        guard photo != nil else { exportSummaryThumbnail = .unavailable; return }
        guard document?.previewError == nil else { exportSummaryThumbnail = .unavailable; return }
        // While another photo opens the last one's frame is still up: no picture of it.
        guard document?.phase == .ready, let frame = currentEditedFrame else { exportSummaryThumbnail = .loading; return }
        let ticket = summaryThumbnailTicket, epoch = thumbnailEpoch
        let framing = thumbnailFraming()
        let deadline = summaryThumbnailLastStart.map { $0 + .milliseconds(200) }
        summaryThumbnailTask = Task { [weak self] in
            if let deadline { do { try await ContinuousClock().sleep(until: deadline) } catch { return } }
            guard let self, !Task.isCancelled, thumbnailEpoch == epoch else { return }
            summaryThumbnailLastStart = .now
            let image = await makeThumbnail(of: frame, maxPixelSize: 344, framing: framing)
            guard !Task.isCancelled, thumbnailEpoch == epoch, summaryThumbnailTicket == ticket,
                  !thumbnailTrackers.isEmpty else { return }
            exportSummaryThumbnail = image.map(ThumbnailState.ready) ?? .unavailable
            summaryThumbnailFrame = image == nil ? nil : frame
        }
    }

    /// What a framed export looks like, as of now; nil without a frame, or when
    /// the engine refuses the style for this photograph (the export is blocked
    /// then, and the bare photograph is the best picture of it).
    func thumbnailFraming() -> ThumbnailFraming? {
        FrameThumbnail.framing(settings: frame, layout: frameLayout, facts: captureFacts)
    }

    /// The picture of an edited frame for `maxPixelSize`: the SDR base, or with
    /// `framing` the whole framed card at that size (M3 §20.3 rule 2). The
    /// photograph is shrunk by the service, off the main actor; only the small
    /// composition happens here.
    func makeThumbnail(of frame: EditorFrame, maxPixelSize: Int, framing: ThumbnailFraming?) async -> CGImage? {
        guard let framing else { return await sdrThumbnail(of: frame, maxPixelSize: maxPixelSize) }
        let geometry = FrameThumbnailGeometry(layout: framing.layout, maxPixelSize: maxPixelSize)
        guard let photo = await sdrThumbnail(of: frame, maxPixelSize: geometry.photoPixelSize),
              !Task.isCancelled else { return nil }
        return FrameThumbnail.compose(photo: photo, framing: framing, maxPixelSize: maxPixelSize)
    }

    /// The SDR base of `frame` within a `maxPixelSize` square (R9).
    func sdrThumbnail(of frame: EditorFrame, maxPixelSize: Int) async -> CGImage? {
        let side = max(1, maxPixelSize)
        return try? await editor.sdrThumbnail(of: frame, maximumSize: HyperDRRender.PixelSize(width: side, height: side))
    }

    func frozenExportThumbnailFrame() -> EditorFrame? {
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
        let epoch = thumbnailEpoch, revision = exportThumbnailEditGeneration, framing = exportThumbnailFraming
        deferredExportThumbnailTask = Task { [weak self] in
            guard let self else { return }
            let image = await makeThumbnail(of: frame, maxPixelSize: 256, framing: framing)
            guard !Task.isCancelled, thumbnailEpoch == epoch else { return }
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
        exportThumbnailFraming = nil
        versionThumbnailQueue = []; versionThumbnailOrder = []; versionThumbnails = [:]
        exportSummaryThumbnail = .loading
    }
}
