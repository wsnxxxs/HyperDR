import CoreGraphics
import Foundation
import HyperDRRender

/// The renderer of a Mac without Metal (or a release build's fake services):
/// every photo fails to open with the reason, as the canvas did before.
actor UnavailableEditorRendering: EditorRendering {
    let reason: String
    init(reason: String) { self.reason = reason }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?) async throws -> EditorSource {
        throw UserFacingError(code: "metal_unavailable", detail: reason)
    }
    func render(_ request: EditorRenderRequest) async throws -> EditorFrame { throw EditorRenderingError.noSource }
    func sdrThumbnail(_ frame: EditorFrame, maximumSize: HyperDRRender.PixelSize) async throws -> CGImage {
        throw EditorRenderingError.noSource
    }
    func effectMask(_ request: EditorRenderRequest, parameterID: String) async throws -> RenderMask {
        throw EditorRenderingError.noSource
    }
    func predictModelGain(_ request: EditorRenderRequest) async throws { throw EditorRenderingError.modelUnavailable(reason) }
    func installLUT(_ lut: ColorLUT) async {}
    func close() async {}
}
