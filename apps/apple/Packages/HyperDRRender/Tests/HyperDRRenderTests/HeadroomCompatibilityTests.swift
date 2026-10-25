import CoreImage
import Foundation
import Testing
@testable import HyperDRRender

@Suite struct HeadroomCompatibilityTests {
    @Test func legacyBindingRetainsHeadroomWithoutChangingImage() {
        let image = CIImage(color: CIColor(red: 4, green: 2, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let bound = HeadroomImage(image, headroom: 6.5, writesImageMetadata: false)
        #expect(bound.image === image)
        #expect(bound.fallbackHeadroom == 6.5)
    }

    @available(macOS 26, iOS 26, *)
    @Test func legacyRAWMaterializationPreservesHeadroomAndPixels() async throws {
        let image = CIImage(color: CIColor(red: 4, green: 2, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
            .settingContentHeadroom(6.5)
        let opened = OpenedSource(domain: .rawEDR, image: image, hdr: image,
            baseSpace: RenderEngine.workingColorSpace, gain: nil, raw: nil)
        let engine = try RenderEngine()
        let modern = try await engine.materialize(opened)
        let legacy = try await engine.materialize(opened, useImageHeadroom: false)
        #expect(modern.fallbackHDRHeadroom == nil)
        #expect(legacy.fallbackHDRHeadroom == 6.5)
        #expect(legacy.hdrContentHeadroom == modern.hdrContentHeadroom)
        #expect(RenderEngine.readTexture(legacy.texture) == RenderEngine.readTexture(modern.texture))
        let modernPlanes = try await engine.render(modern)
        let legacyPlanes = try await engine.render(legacy)
        #expect(RenderEngine.readPixels(legacyPlanes).baseRGBA == RenderEngine.readPixels(modernPlanes).baseRGBA)
        #expect(RenderEngine.readPixels(legacyPlanes).gain == RenderEngine.readPixels(modernPlanes).gain)
    }
}
