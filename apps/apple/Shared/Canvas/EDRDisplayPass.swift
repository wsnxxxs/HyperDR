import HyperDRRender
import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// The part of the EDR canvas that does not depend on the platform or on where
/// the pixels came from, shared by the Mac and iOS targets: the layer setup,
/// the intermediate texture, and pass 2, which draws that texture into the
/// drawable through `CanvasTransform`. The view that hosts the layer (NSView,
/// UIView), the display headroom and the gestures stay in each platform layer.

/// A renderer failure. The message is a developer-facing English detail: the
/// model reports it as `metal_unavailable`, whose title and message come from
/// the catalogue, and `ErrorText` shows the detail untranslated.
nonisolated enum PreviewError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Matches `DisplayParams` in EDRDisplay.metal.
nonisolated struct DisplayParams {
    var rect: SIMD4<Float>
}

nonisolated struct EDRDisplayPass: @unchecked Sendable {
    let pipeline: any MTLRenderPipelineState

    init(device: any MTLDevice, library: any MTLLibrary) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        for name in ["previewDisplayVertex", "previewDisplayFragment"] where library.makeFunction(name: name) == nil {
            throw PreviewError.unavailable("Missing Metal function \(name)")
        }
        descriptor.vertexFunction = library.makeFunction(name: "previewDisplayVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "previewDisplayFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard MemoryLayout<DisplayParams>.stride == 16 else {
            throw PreviewError.unavailable("Preview shader parameter layout changed")
        }
    }

    /// Extended linear Display P3 in half floats: values above 1 reach the
    /// display's EDR headroom. Only the photo rect is opaque; the rest of the
    /// canvas is clear so the SwiftUI backdrop shows through.
    static func configure(_ layer: CAMetalLayer, device: any MTLDevice) {
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.framebufferOnly = true
    }

    /// Clears `drawable` and draws `texture` (rgba16Float, mipmapped) into the
    /// photo rect of `transform`.
    func encode(_ texture: any MTLTexture, transform: CanvasTransform,
                into drawable: any CAMetalDrawable, drawableSize: CGSize, command: any MTLCommandBuffer) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: Self.clearPass(drawable)) else { return }
        encoder.setRenderPipelineState(pipeline)
        var params = DisplayParams(rect: Self.normalisedRect(transform, drawableSize: drawableSize))
        encoder.setVertexBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    static func clearPass(_ drawable: any CAMetalDrawable) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// The photo rect in normalised device coordinates, y up. Edges snap to
    /// whole device pixels so a 100% view lands on the source grid instead of
    /// resampling by a fraction of a pixel.
    static func normalisedRect(_ transform: CanvasTransform,
                               drawableSize: CGSize) -> SIMD4<Float> {
        let frame = transform.imageFrame
        let width = max(drawableSize.width, 1)
        let height = max(drawableSize.height, 1)
        let scale = width / max(transform.viewport.width, 1)
        func pixel(_ points: CGFloat) -> Float {
            Float((points * scale).rounded())
        }
        let x0 = 2 * pixel(frame.minX) / Float(width) - 1
        let x1 = 2 * pixel(frame.maxX) / Float(width) - 1
        let bottom = 1 - 2 * pixel(frame.maxY) / Float(height)
        let top = 1 - 2 * pixel(frame.minY) / Float(height)
        return SIMD4<Float>(x0, bottom, x1, top)
    }

    /// The texture pass 2 samples: rgba16Float, one texel per source pixel,
    /// with mips so a zoomed-out photo does not alias.
    static func intermediateTexture(device: any MTLDevice, width: Int, height: Int,
                                    usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws
        -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: max(width, 1), height: max(height, 1), mipmapped: true)
        descriptor.usage = usage
        descriptor.storageMode = .private
        return try makeTexture(device: device, descriptor: descriptor)
    }

    static func makeTexture(device: any MTLDevice, descriptor: MTLTextureDescriptor) throws -> any MTLTexture {
        let limit = RenderEngine.maximumTextureDimension(device:device)
        guard descriptor.width > 0, descriptor.height > 0, descriptor.width <= limit, descriptor.height <= limit else {
            throw PreviewError.unavailable("Composition dimensions exceed this device's texture limit")
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreviewError.unavailable("Unable to allocate a Metal texture")
        }
        return texture
    }
}

/// The display's EDR headroom as last read from the screen: `current` is what
/// is usable now, `potential` the most the display can reach.
nonisolated struct HeadroomSnapshot: Equatable, Sendable {
    var screen: String? = nil
    var current: CGFloat = 1
    var potential: CGFloat = 1
    var reference: CGFloat = 1
}
