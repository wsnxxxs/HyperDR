import Foundation
import HyperDRKit
import HyperDRRecipe

/// The editor's export capture in Kit's terms, for the Mac and iOS hosts.
extension EditorExportCapture {
    /// The frozen snapshot, with the revision captured when the photo was
    /// opened. The service reads the model selection from the recipe's
    /// `hdr.model`; an expected model identity is only for re-rendering history.
    func snapshot(revision: RecipeSourceRevision) -> RecipeExportSnapshot {
        RecipeExportSnapshot(recipe: recipe, source: revision)
    }

    /// What Kit plans the export from, with the host's encoder facts
    /// (`ExportEncodingCapabilities`). No frame yet on iOS (P7-3b-U).
    func planRequest(_ choice: ExportChoice, frame: ExportFrameFacts = ExportFrameFacts(),
                     capabilities: ExportEncodingCapabilities = .init()) -> ExportPlanRequest {
        ExportPlanRequest(choice: choice,
                          source: ExportSource(domain: source.domain,
                                               pixelSize: ExportPixelSize(width: source.pixelSize.width,
                                                                          height: source.pixelSize.height),
                                               hasAlpha: source.hasAlpha),
                          frame: frame,
                          edit: ExportEditFacts(hdrEnabled: hdrEnabled, peakStops: peakStops),
                          capabilities: capabilities)
    }
}
