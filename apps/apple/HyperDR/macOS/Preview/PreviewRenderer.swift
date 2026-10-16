import AppKit
import Metal
import QuartzCore

struct PreviewParams {
    var original: Float = 0
    var width: Float = 512
    var height: Float = 128
    var compact: Float = 0
    var gainMin: Float = 0
    var gainMax: Float = 3
    var inverseGamma: Float = 1
    var baseOffset: Float = 0
    var alternateOffset: Float = 0
    var gainWeight: Float = 1
    var pad1: Float = 0
    var pad2: Float = 0
}

enum PreviewError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

final class PreviewRenderer {
    let device: any MTLDevice
    let library: any MTLLibrary
    let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let base: any MTLTexture
    private let hdr: any MTLTexture
    private var params = PreviewParams()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PreviewError.unavailable("Metal 设备不可用")
        }
        self.device = device
        self.queue = queue
        library = try device.makeDefaultLibrary(bundle: Bundle(for: EDRMetalView.self))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "previewVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "previewFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var basePixels = [Float](), hdrPixels = [Float]()
        for y in 0..<128 {
            for x in 0..<512 {
                let value = Float(x) / 511 * 8
                let tint: SIMD3<Float> = y < 43 ? SIMD3(1, 0.65, 0.3) : y < 86 ? SIMD3(repeating: 1) : SIMD3(0.2, 0.65, 1)
                let rgb = tint * value
                hdrPixels += [rgb.x, rgb.y, rgb.z, 1]
                basePixels += [min(rgb.x, 1), min(rgb.y, 1), min(rgb.z, 1), 1]
            }
        }
        base = try Self.texture(device: device, width: 512, height: 128, values: basePixels)
        hdr = try Self.texture(device: device, width: 512, height: 128, values: hdrPixels)
    }

    static func texture(device: any MTLDevice, width: Int, height: Int, values: [Float], monochrome: Bool = false) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: monochrome ? .r32Float : .rgba32Float,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreviewError.unavailable("无法分配 Metal 纹理")
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * (monochrome ? 4 : 16))
        }
        return texture
    }

    func draw(in layer: CAMetalLayer, original: Bool) {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else { return }
        encode(into: drawable.texture, command: command, original: original)
        command.present(drawable)
        command.commit()
    }

    func encode(into texture: any MTLTexture, command: any MTLCommandBuffer, original: Bool) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        params.original = original ? 1 : 0
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(base, index: 0)
        encoder.setFragmentTexture(hdr, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<PreviewParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

}
