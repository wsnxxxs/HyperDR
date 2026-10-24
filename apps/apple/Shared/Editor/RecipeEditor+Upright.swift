import Foundation
import HyperDRRecipe
import HyperDRRender

/// The crop pane's Auto: finds the photo's straight lines and solves the
/// straightening and perspective that make them upright, as one undo step.
///
/// Contract for the views:
/// - `autoUpright(_:)` starts the analysis and returns at once; calling it
///   again while one runs restarts it with the new mode.
/// - `uprightStatus` is `.analyzing` while it runs, then `.idle` once the
///   geometry is applied, or `.noLines` / `.failed` when nothing was applied.
///   Any later geometry edit or leaving the crop pane returns it to `.idle`.
extension RecipeEditor {
    enum UprightStatus: Equatable, Sendable {
        case idle
        case analyzing(UprightMode)
        /// Not enough straight lines to decide; the geometry is unchanged.
        case noLines
        /// The analysis failed (render error); the geometry is unchanged.
        case failed
    }

    func autoUpright(_ mode: UprightMode = .auto) {
        cancelUpright()
        guard let source, !isOpening else { return }
        let generation = uprightGeneration
        let geometry = recipe.geometry
        let photo = GeometrySize(width: Double(source.pixelSize.width), height: Double(source.pixelSize.height))
        let sourceID = source.id
        let cached = uprightLines.flatMap { $0.source == sourceID ? $0.lines : nil }
        var analysisRecipe = recipe
        analysisRecipe.geometry = .identity
        let side = min(1536, max(source.pixelSize.width, source.pixelSize.height))
        let size = HyperDRRender.PixelSize(width: max(1, Int(photo.width * Double(side) / max(photo.width, photo.height))),
                                           height: max(1, Int(photo.height * Double(side) / max(photo.width, photo.height))))
        // A cached preview may still carry the previous crop/RAW variant.
        // Permit preparation to load this exact identity geometry; keepsSource
        // would either reuse cropped raster coordinates or reject a RAW change.
        let request = EditorRenderRequest(sourceID: sourceID, recipe: analysisRecipe, size: size)
        let renderer = self.renderer
        uprightStatus = .analyzing(mode)
        EditorLog.notice("Upright analysis started")
        uprightTask = Task { [weak self] in
            let start = Date.timeIntervalSinceReferenceDate
            do {
                let lines: [UprightLine]
                if let cached { lines = cached }
                else {
                    let frame = try await renderer.render(request)
                    let image = try await renderer.sdrThumbnail(frame, maximumSize: size)
                    try Task.checkCancellation()
                    let detection = Task.detached(priority: .userInitiated) {
                        try LineSegmentDetector.detect(image, photoSize: photo)
                    }
                    lines = try await withTaskCancellationHandler { try await detection.value } onCancel: { detection.cancel() }
                }
                try Task.checkCancellation()
                guard let self, self.source?.id == sourceID, self.uprightGeneration == generation else { return }
                self.uprightLines = (sourceID, lines)
                let fitting = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return UprightSolver.solve(lines: lines, photo: photo, geometry: geometry, mode: mode)
                }
                let result = try await withTaskCancellationHandler { try await fitting.value } onCancel: { fitting.cancel() }
                try Task.checkCancellation()
                guard self.source?.id == sourceID, self.uprightGeneration == generation else { return }
                self.uprightTask = nil
                EditorLog.notice("Upright analysis finished: lines=\(lines.count) elapsed_ms=\(Int((Date.timeIntervalSinceReferenceDate - start) * 1000))")
                guard let result else { self.uprightStatus = .noLines; return }
                self.uprightStatus = .idle
                self.apply(.geometry) { $0.geometry = result }
            } catch is CancellationError {
                // Superseding, closing and edits already reset the status.
                // A renderer may also cancel independently of this task.
                guard let self, self.uprightGeneration == generation else { return }
                self.uprightTask = nil
                self.uprightStatus = .idle
            } catch {
                guard let self, !Task.isCancelled, self.source?.id == sourceID,
                      self.uprightGeneration == generation else { return }
                self.uprightTask = nil
                self.uprightStatus = .failed
                EditorLog.error("Upright analysis failed: \(EditorLog.describe(error))")
            }
        }
    }

    func cancelUpright(clearCache: Bool = false) {
        uprightGeneration += 1
        uprightTask?.cancel()
        uprightTask = nil
        uprightStatus = .idle
        if clearCache { uprightLines = nil }
    }
}
