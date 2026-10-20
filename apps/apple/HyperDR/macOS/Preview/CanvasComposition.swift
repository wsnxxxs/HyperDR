import CoreGraphics
import HyperDREngine
import Metal

/// Immutable state captured by the main actor. The executor owns all GPU
/// resources; photo pixel storage stays alive through these frame references.
nonisolated struct CanvasComposition: @unchecked Sendable {
    typealias Mode = DisplayComposition.Mode
    var original: PreviewFrame?
    var edited: PreviewFrame
    var originalDetail: PreviewFrame?
    var editedDetail: PreviewFrame?
    var mode: Mode = .edited
    var splitRatio = 0.5
    var headroom = 1.0
    var overlays = CanvasOverlays()
    var previewsAsSDR = false
    var presentationTrace: PreviewTrace? = nil
    var originalDetailTrace: PreviewTrace? = nil
    var editedDetailTrace: PreviewTrace? = nil

    /// Whole-image work belongs to this publication, not cached provenance.
    var primaryTrace: PreviewTrace? {
        presentationTrace ?? (mode == .original ? original?.trace : edited.trace)
    }
    /// Only layers actually drawn may complete an independent detail request.
    var presentedTraces: [PreviewTrace] {
        var traces = [primaryTrace]
        if mode != .edited, original != nil, let frame = originalDetail,
           CanvasCompositor.region(frame) != nil { traces.append(originalDetailTrace ?? primaryTrace) }
        if mode != .original, let frame = editedDetail,
           CanvasCompositor.region(frame) != nil { traces.append(editedDetailTrace ?? primaryTrace) }
        var seen = Set<ObjectIdentifier>()
        return traces.compactMap { $0 }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

/// Hands the engine's preview frames to the shared `DisplayCompositor` as
/// display pairs, uploading each frame once per layer in the presenting
/// command buffer. A bridge until the Mac editor renders through
/// HyperDRRender (P7-2b step 4), which then builds the pairs itself.
nonisolated final class CanvasCompositor {
    let display: DisplayCompositor
    private let device: any MTLDevice
    private let upload: any MTLComputePipelineState
    private enum Layer { case original, edited, originalDetail, editedDetail }
    /// Each layer keeps its own upload, as the compositor keeps its own cache.
    private var uploads: [Layer: (frame: PreviewFrame, pair: DisplayPair)] = [:]
    var rebuilds: Int { display.rebuilds }
    var textureAllocations: Int { display.textureAllocations }

    init(device: any MTLDevice, library: any MTLLibrary) throws {
        self.device = device
        display = try DisplayCompositor(device: device, library: library)
        guard let function = library.makeFunction(name: "uploadPreviewFrame") else {
            throw PreviewError.unavailable("Missing preview upload shader")
        }
        upload = try device.makeComputePipelineState(function: function)
    }

    func releaseFrames() {
        uploads = [:]
        display.releasePairs()
    }

    private func texture(_ format: MTLPixelFormat, width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreviewError.unavailable("Unable to allocate preview upload texture")
        }
        return texture
    }

    /// Encodes the copy of `frame`'s planes into new textures.
    func upload(_ frame: PreviewFrame, command: any MTLCommandBuffer, trace: PreviewTrace? = nil) throws -> DisplayPair {
        let planes = try FramePlanes(frame, device: device, trace: trace)
        let mono = planes.gainChannels == 1
        let base = try texture(.rgba16Float, width: planes.width, height: planes.height)
        let gain = mono ? try texture(.r32Float, width: planes.gainWidth, height: planes.gainHeight)
                        : try texture(.rgba16Float, width: planes.width, height: planes.height)
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw PreviewError.unavailable("Unable to create preview upload encoder")
        }
        var params = ReconstructParams(planes: planes, original: false)
        encoder.setComputePipelineState(upload)
        encoder.setBuffer(planes.base, offset: 0, index: 0)
        encoder.setBuffer(planes.gain, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ReconstructParams>.stride, index: 2)
        encoder.setTexture(base, index: 0)
        encoder.setTexture(gain, index: 1)
        encoder.dispatchThreads(MTLSize(width: max(planes.width, mono ? planes.gainWidth : 0),
                                        height: max(planes.height, mono ? planes.gainHeight : 0), depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        let m = frame.metadata
        return DisplayPair(base: base, gain: gain,
            coding: mono ? .isoCode(minimum: planes.gainMin, maximum: planes.gainMax, gamma: planes.gainGamma) : .alternate,
            baseOffset: SIMD3(repeating: planes.baseOffset), alternateOffset: SIMD3(repeating: planes.alternateOffset),
            baseHeadroom: m.baseHeadroom ?? 0, alternateHeadroom: m.alternateHeadroom ?? m.headroomStops,
            region: Self.region(frame))
    }

    private func pair(_ frame: PreviewFrame, _ layer: Layer, command: any MTLCommandBuffer,
                      trace: PreviewTrace?) throws -> DisplayPair {
        if let cached = uploads[layer], cached.frame === frame { return cached.pair }
        let pair = try upload(frame, command: command, trace: trace)
        uploads[layer] = (frame, pair)
        return pair
    }

    /// All preparation and the complete display pass share the ONE presenting
    /// command buffer supplied by PreviewRenderer's in-flight gate. On failure
    /// it is never committed, so no upload it carried is kept.
    func encode(_ content: CanvasComposition, transform: CanvasTransform, target: any MTLTexture,
                command: any MTLCommandBuffer) throws {
        do { try encodeComposition(content, transform: transform, target: target, command: command) }
        catch { uploads = [:]; throw error }
    }

    private func encodeComposition(_ content: CanvasComposition, transform: CanvasTransform, target: any MTLTexture,
                                   command: any MTLCommandBuffer) throws {
        let primary = content.primaryTrace
        let editedTrace = primary ?? content.edited.trace
        var shown = DisplayComposition(
            edited: try pair(content.edited, .edited, command: command, trace: editedTrace),
            mode: content.mode, splitRatio: content.splitRatio, headroom: content.headroom,
            overlays: content.overlays, previewsAsSDR: content.previewsAsSDR, editedTrace: editedTrace)
        // Also when only its detail needs it: that detail's weight follows it.
        if let frame = content.original, content.mode != .edited || content.originalDetail != nil {
            let trace = primary ?? frame.trace
            shown.original = try pair(frame, .original, command: command, trace: trace)
            shown.originalTrace = trace
        }
        if let frame = content.originalDetail {
            let trace = content.originalDetailTrace ?? primary ?? frame.trace
            shown.originalDetail = try pair(frame, .originalDetail, command: command, trace: trace)
            shown.originalDetailTrace = trace
        } else { uploads[.originalDetail] = nil }
        if let frame = content.editedDetail {
            let trace = content.editedDetailTrace ?? primary ?? frame.trace
            shown.editedDetail = try pair(frame, .editedDetail, command: command, trace: trace)
            shown.editedDetailTrace = trace
        } else { uploads[.editedDetail] = nil }
        try display.encode(shown, transform: transform, target: target, command: command)
    }

    static func region(_ frame: PreviewFrame) -> CGRect? {
        let m = frame.metadata
        guard m.detail == true, let x = m.regionX, let y = m.regionY else { return nil }
        return CGRect(x: x, y: y, width: m.width, height: m.height)
    }
}
