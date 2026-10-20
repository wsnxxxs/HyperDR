import Foundation
import CoreGraphics
import Metal
import HyperDRRecipe

/// Point nodes return the requested region unchanged; spatial nodes expand it
/// by their halo. Coordinates are in output pixels, top-left origin.
public protocol RenderNode: Sendable {
    static var parameters: [ParameterDeclaration] { get }
    /// Includes all values that affect this node's result.
    var cacheKey: String { get }
    var isIdentity: Bool { get }
    func inputRegion(for outputRegion: CGRect, imageSize: PixelSize) -> CGRect
    func encode(_ input: RenderPlanes, context: RenderNodeContext) throws -> RenderPlanes
}

public struct IdentityNode: RenderNode {
    public static let parameters: [ParameterDeclaration] = []
    public let cacheKey = "identity/v1"
    public let isIdentity = true
    public init() {}
    public func inputRegion(for region: CGRect, imageSize: PixelSize) -> CGRect { region }
    public func encode(_ input: RenderPlanes, context: RenderNodeContext) throws -> RenderPlanes { input }
}

public struct SourceHDRSplitNode: RenderNode {
    public static let parameters = [ParameterDeclaration(
        id: "hdr.range", group: .hdr, kind: .floatOrAuto, range: 0.5...4, step: 0.1,
        default: .auto, format: .stops, visibleWhen: .isOn("hdr.enabled"), scope: .hdrOnly, mask: "gain")]
    /// Resolved output capacity in stops; automatic resolution currently defaults to 3.
    /// P7-1 separates the HDR-only range operation from this source decomposition.
    public let headroom: Float
    public var cacheKey: String { "sourceHDRSplit/v1/\(headroom.bitPattern)" }
    public let isIdentity = false
    public init(headroom: Float = 3) { self.headroom = headroom }
    public func inputRegion(for region: CGRect, imageSize: PixelSize) -> CGRect { region }
    public func encode(_ input: RenderPlanes, context: RenderNodeContext) throws -> RenderPlanes {
        guard headroom.isFinite, (0...4).contains(headroom) else { throw RenderError.invalidSize }
        // An unedited authored pair and SDR input are already separated.
        if input.provenance == .authored || context.domain == .sdr { return input }
        let base = try context.texture(width: input.base.width, height: input.base.height)
        let gain = try context.texture(width: input.base.width, height: input.base.height, format: .r32Float)
        var value = headroom
        try context.dispatch("sourceHDRSplit", width: base.width, height: base.height,
                             textures: [input.base, base, gain], value: &value)
        return RenderPlanes(base: base, gain: gain, baseColorSpace: context.workingSpace,
                            provenance: context.domain == .dual ? .resplit : .split,
                            region: input.region)
    }
}

/// GPU services for node implementations. All nodes in one stripe encode into
/// the same command buffer; completion and cancellation belong to RenderEngine.
public final class RenderNodeContext {
    public let domain: InputDomain
    public let device: any MTLDevice
    public let commandBuffer: any MTLCommandBuffer
    public let workingSpace: CGColorSpace
    let library: any MTLLibrary
    private var pipelines: [String: any MTLComputePipelineState]

    init(domain: InputDomain, device: any MTLDevice, commandBuffer: any MTLCommandBuffer,
         workingSpace: CGColorSpace, library: any MTLLibrary,
         pipelines: [String: any MTLComputePipelineState]) {
        self.domain = domain
        self.device = device
        self.commandBuffer = commandBuffer
        self.workingSpace = workingSpace
        self.library = library
        self.pipelines = pipelines
    }

    public func texture(width: Int, height: Int, format: MTLPixelFormat = .rgba32Float) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocationFailed }
        return texture
    }

    /// For package kernels. New nodes may also encode their own Metal pipelines
    /// directly with device/commandBuffer, without changing the scheduler.
    func dispatch<T: BitwiseCopyable>(_ name: String, width: Int, height: Int,
                     textures: [any MTLTexture], value: inout T) throws {
        let pipeline: any MTLComputePipelineState
        if let cached = pipelines[name] { pipeline = cached } else {
            guard let function = library.makeFunction(name: name) else { throw RenderError.gpu(name) }
            pipeline = try device.makeComputePipelineState(function: function)
            pipelines[name] = pipeline
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.allocationFailed }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        encoder.setBytes(&value, length: MemoryLayout<T>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }
}
