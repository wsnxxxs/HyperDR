import Foundation
import CoreGraphics
import Metal
import HyperDRRecipe
#if DEBUG || HYPERDR_FILM_PROFILE
import Darwin
import Synchronization

/// Diagnostic builds count actual context-local pipeline misses. No resources
/// are retained, and production Release builds compile this bookkeeping out.
struct RenderPipelineSnapshot: Sendable, Codable {
    struct Context: Sendable, Codable {
        var dispatches: [String: Int] = [:]
        var creations: [String: Int] = [:]
        var textureCount = 0
        var allocatedTextureBytes = 0
    }
    struct Phase: Sendable, Codable {
        let sequence: Int
        let context: String?
        let name: String
        let width, height: Int
        let footprintBytes, lifetimePeakFootprintBytes, metalAllocatedBytes: UInt64
    }
    struct PhaseSummary: Sendable, Codable {
        var count = 0
        var maximumFootprintBytes: UInt64 = 0
        var maximumLifetimePeakFootprintBytes: UInt64 = 0
        var maximumMetalAllocatedBytes: UInt64 = 0
    }
    var dispatches: [String: Int] = [:]
    var creations: [String: Int] = [:]
    var creationSeconds: [String: Double] = [:]
    var contextCount = 0
    var contexts: [String: Context] = [:]
    var contextsTruncated = false
    var maximumMetalAllocatedBytes: UInt64 = 0
    var phaseCount = 0
    var phases: [Phase] = []
    var phasesTruncated = false
    var phaseSummary: [String: PhaseSummary] = [:]
}

enum RenderPipelineDiagnostics {
    private static let state = Mutex(RenderPipelineSnapshot())
    static func snapshot() -> RenderPipelineSnapshot { state.withLock { $0 } }
    static func context() -> String {
        state.withLock {
            $0.contextCount += 1
            let id = String($0.contextCount)
            if $0.contexts.count < 4096 { $0.contexts[id] = .init() }
            else { $0.contextsTruncated = true }
            return id
        }
    }
    static func dispatch(_ name: String, context: String, creationSeconds: Double?, allocatedBytes: UInt64) {
        state.withLock {
            $0.dispatches[name, default: 0] += 1
            $0.contexts[context]?.dispatches[name, default: 0] += 1
            if let creationSeconds {
                $0.creations[name, default: 0] += 1
                $0.creationSeconds[name, default: 0] += creationSeconds
                $0.contexts[context]?.creations[name, default: 0] += 1
            }
            $0.maximumMetalAllocatedBytes = max($0.maximumMetalAllocatedBytes, allocatedBytes)
        }
    }
    static func texture(context: String, bytes: Int, allocatedBytes: UInt64) {
        state.withLock {
            $0.contexts[context]?.textureCount += 1
            $0.contexts[context]?.allocatedTextureBytes += bytes
            $0.maximumMetalAllocatedBytes = max($0.maximumMetalAllocatedBytes, allocatedBytes)
        }
    }
    static func phase(_ name: String, device: any MTLDevice, context: String? = nil,
                      width: Int = 0, height: Int = 0) {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = status == KERN_SUCCESS ? vm.phys_footprint : 0
        let peak = status == KERN_SUCCESS ? UInt64(max(0, vm.ledger_phys_footprint_peak)) : 0
        let allocated = UInt64(device.currentAllocatedSize)
        state.withLock {
            $0.phaseCount += 1
            var summary = $0.phaseSummary[name, default: .init()]
            summary.count += 1
            summary.maximumFootprintBytes = max(summary.maximumFootprintBytes, footprint)
            summary.maximumLifetimePeakFootprintBytes = max(summary.maximumLifetimePeakFootprintBytes, peak)
            summary.maximumMetalAllocatedBytes = max(summary.maximumMetalAllocatedBytes, allocated)
            $0.phaseSummary[name] = summary
            $0.maximumMetalAllocatedBytes = max($0.maximumMetalAllocatedBytes, allocated)
            if $0.phases.count < 8192 {
                $0.phases.append(.init(sequence: $0.phaseCount, context: context, name: name,
                    width: width, height: height, footprintBytes: footprint,
                    lifetimePeakFootprintBytes: peak, metalAllocatedBytes: allocated))
            } else { $0.phasesTruncated = true }
        }
    }
}
#endif

/// Point nodes return the requested region unchanged; spatial nodes expand it
/// by their halo. Coordinates are in output pixels, top-left origin.
public protocol RenderNode: Sendable {
    static var parameters: [ParameterDeclaration] { get }
    static var parameterIDs: [String] { get }
    /// Includes all values that affect this node's result.
    var cacheKey: String { get }
    var isIdentity: Bool { get }
    func inputRegion(for outputRegion: CGRect, imageSize: PixelSize) -> CGRect
    func encode(_ input: RenderPlanes, context: RenderNodeContext) throws -> RenderPlanes
}

public extension RenderNode {
    static var parameterIDs: [String] { parameters.map(\.id) }
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
    public static let parameters: [ParameterDeclaration] = []
    public static let parameterIDs: [String] = []
    public let cacheKey = "sourceHDRSplit/v2"
    public let isIdentity = false
    public init() {}
    public func inputRegion(for region: CGRect, imageSize: PixelSize) -> CGRect { region }
    public func encode(_ input: RenderPlanes, context: RenderNodeContext) throws -> RenderPlanes {
        // An unedited authored pair and SDR input are already separated.
        if input.provenance == .authored || context.domain == .sdr { return input }
        let base = try context.texture(width: input.base.width, height: input.base.height)
        let gain = try context.texture(width: input.base.width, height: input.base.height, format: .r32Float)
        var value: UInt32 = 0
        try context.dispatch("sourceHDRSplit", width: base.width, height: base.height,
                             textures: [input.base, base, gain], value: &value)
        return RenderPlanes(base: base, gain: gain, baseColorSpace: context.workingSpace,
                            provenance: context.domain == .dual ? .resplit : .split,
                            region: input.region, outputSize:input.outputSize, aiPending:input.aiPending)
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
#if DEBUG || HYPERDR_FILM_PROFILE
    private let diagnosticContext = RenderPipelineDiagnostics.context()
    private(set) var diagnosticPipelineCreations: [String: Int] = [:]
#endif

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

#if DEBUG || HYPERDR_FILM_PROFILE
    func diagnosticPhase(_ name: String, width: Int = 0, height: Int = 0) {
        RenderPipelineDiagnostics.phase(name, device: device, context: diagnosticContext, width: width, height: height)
    }
#endif

    public func texture(width: Int, height: Int, format: MTLPixelFormat = .rgba32Float) throws -> any MTLTexture {
        try device.validateTexture(width: width, height: height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocationFailed }
#if DEBUG || HYPERDR_FILM_PROFILE
        RenderPipelineDiagnostics.texture(context: diagnosticContext, bytes: texture.allocatedSize,
            allocatedBytes: UInt64(device.currentAllocatedSize))
#endif
        return texture
    }

    /// For package kernels. New nodes may also encode their own Metal pipelines
    /// directly with device/commandBuffer, without changing the scheduler.
    func dispatch<T: BitwiseCopyable>(_ name: String, width: Int, height: Int,
                     textures: [any MTLTexture], buffers: [any MTLBuffer] = [], value: inout T) throws {
        let pipeline: any MTLComputePipelineState
#if DEBUG || HYPERDR_FILM_PROFILE
        var creationSeconds: Double?
#endif
        if let cached = pipelines[name] { pipeline = cached } else {
#if DEBUG || HYPERDR_FILM_PROFILE
            let start = ContinuousClock.now
#endif
            guard let function = library.makeFunction(name: name) else { throw RenderError.gpu(name) }
            pipeline = try device.makeComputePipelineState(function: function)
            pipelines[name] = pipeline
#if DEBUG || HYPERDR_FILM_PROFILE
            let duration = start.duration(to: .now).components
            creationSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            diagnosticPipelineCreations[name, default: 0] += 1
#endif
        }
#if DEBUG || HYPERDR_FILM_PROFILE
        RenderPipelineDiagnostics.dispatch(name, context: diagnosticContext, creationSeconds: creationSeconds,
            allocatedBytes: UInt64(device.currentAllocatedSize))
#endif
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.allocationFailed }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index + 1) }
        encoder.setBytes(&value, length: MemoryLayout<T>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }
}

public enum AdjustmentOperation: UInt32, CaseIterable, Sendable {
    case exposure, contrast, highlights, shadows, blacks, warmth, tint, vibrance, saturation, whites
    public var parameterID: String {
        ["tone.exposure", "tone.contrast", "tone.highlights", "tone.shadows", "tone.blacks",
         "color.warmth", "color.tint", "color.vibrance", "color.saturation", "tone.whites"][Int(rawValue)]
    }
}

/// Pointwise light/color nodes. The full graph fuses this identical operator
/// sequence; individual nodes remain available for scoped evaluation and tests.
public struct AdjustmentNode: RenderNode {
    public static let parameters = AdjustmentOperation.allCases.map { Adjustments.declaration($0.parameterID)! }
    public let operation: AdjustmentOperation
    public let value: Float
    public init(_ operation: AdjustmentOperation, value: Float) { self.operation = operation; self.value = value }
    public var cacheKey: String { "adjust/v1/\(operation.rawValue)/\(value.bitPattern)" }
    public var isIdentity: Bool { value == RenderParameter.defaultNumber(operation.parameterID) }
    public func inputRegion(for region: CGRect, imageSize: PixelSize) -> CGRect { region }
    public func encode(_ input: RenderPlanes, context: RenderNodeContext) throws -> RenderPlanes {
        try RenderParameter.check(value,id:operation.parameterID)
        if isIdentity { return input }
        guard RenderParameter.declaration(operation.parameterID).allows(context.domain) else { throw RenderError.invalidAdjustment }
        let output = try context.texture(width: input.base.width, height: input.base.height)
        var parameters = PointUniform(operation: operation.rawValue, sdr: context.domain == .sdr ? 1 : 0,
                                      value: value, unused: 0)
        try context.dispatch("adjustPoint", width: output.width, height: output.height,
                             textures: [input.base, output], value: &parameters)
        return RenderPlanes(base: output, gain: input.gain, gainChannelCount: input.gainChannelCount,
            encoding: input.encoding, baseColorSpace: input.baseColorSpace, provenance: input.provenance, region: input.region, outputSize:input.outputSize, aiPending:input.aiPending)
    }
}

struct PointUniform { var operation: UInt32; var sdr: UInt32; var value: Float; var unused: Float }

// Metal has no maxTextureDimension2D query. Use the supported GPU family's
// feature-table limit, with Simulator's smaller software-device limit.
extension MTLDevice {
    var renderTextureLimit: Int {
        #if targetEnvironment(simulator)
        8192
        #else
        supportsFamily(.apple3) || supportsFamily(.mac2) ? 16384 : 8192
        #endif
    }
    func validateTexture(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= renderTextureLimit, height <= renderTextureLimit else {
            throw RenderError.invalidSize
        }
    }
}
