import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender
import Metal

#if DEBUG
/// `EditorRendering` for tests and previews: no files are read, every frame
/// is a small flat texture, and renders and predictions can be held until
/// the test lets them go, to observe cancellation and coalescing. Debug
/// builds only (tests and SwiftUI previews).
actor FakeEditorRendering: EditorRendering {
    struct Photo: Sendable {
        var domain: HyperDRRecipe.InputDomain = .sdr
        var size = HyperDRRender.PixelSize(width: 6000, height: 4000)
        var sourceValues: [String: Double] = [:]
        var capabilities: Set<String> = []
    }

    enum ModelBehavior: Sendable {
        case succeed
        case fail(String)
        case unavailable(String)
    }

    /// What `open` reports, by URL; others open as `defaultPhoto`.
    var photos: [URL: Photo] = [:]
    var defaultPhoto = Photo()
    var modelBehavior = ModelBehavior.succeed

    private(set) var opened: [URL] = []
    /// Every render request in arrival order, finished or not.
    private(set) var requests: [EditorRenderRequest] = []
    private(set) var completed: [EditorRenderRequest] = []
    private(set) var cancelled: [EditorRenderRequest] = []
    private(set) var predictions: [String] = []
    private(set) var installedLUTs: Set<String> = []

    private var current: EditorSource?
    private var holdingRenders = false
    private var holdingPredictions = false
    private var heldRenders: [Int: CheckedContinuation<Void, Never>] = [:]
    private var heldPredictions: [CheckedContinuation<Void, Never>] = []
    private var nextHold = 0
    private var textures: (base: any MTLTexture, gain: any MTLTexture)?

    init() {}

    func configure(_ change: @Sendable (isolated FakeEditorRendering) -> Void) { change(self) }

    // MARK: - Holding

    /// Renders started from now on wait until `releaseRenders`.
    func holdRenders() { holdingRenders = true }

    func releaseRenders() {
        holdingRenders = false
        let held = heldRenders
        heldRenders = [:]
        held.values.forEach { $0.resume() }
    }

    var heldRenderCount: Int { heldRenders.count }

    func holdPredictions() { holdingPredictions = true }

    func releasePredictions() {
        holdingPredictions = false
        let held = heldPredictions
        heldPredictions = []
        held.forEach { $0.resume() }
    }

    var heldPredictionCount: Int { heldPredictions.count }

    private func release(_ id: Int) {
        heldRenders.removeValue(forKey: id)?.resume()
    }

    // MARK: - EditorRendering

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?) async throws -> EditorSource {
        opened.append(url)
        let photo = photos[url] ?? defaultPhoto
        let source = EditorSource(id: UUID(), url: url, domain: photo.domain, pixelSize: photo.size,
                                  sourceValues: photo.sourceValues, capabilities: photo.capabilities)
        current = source
        return source
    }

    func render(_ request: EditorRenderRequest) async throws -> EditorFrame {
        requests.append(request)
        if holdingRenders {
            nextHold += 1
            let id = nextHold
            await withTaskCancellationHandler {
                await withCheckedContinuation { heldRenders[id] = $0 }
            } onCancel: {
                Task { await self.release(id) }
            }
        }
        guard !Task.isCancelled else {
            cancelled.append(request)
            throw CancellationError()
        }
        guard let current else { throw EditorRenderingError.noSource }
        guard current.id == request.sourceID else { throw EditorRenderingError.staleSource }
        if let look = request.recipe.activeLook, !installedLUTs.contains(look.contentHash) {
            throw EditorRenderingError.missingLUT(look.contentHash)
        }
        let planes = try makePlanes(size: request.size)
        completed.append(request)
        let display = DisplayGainPair(base: planes.base, gain: planes.gain, alternateHeadroom: 0,
                                      region: planes.region, outputSize: request.size)
        // "AI pending": without a prediction the frame has no AI gain.
        return EditorFrame(request: request, planes: planes, display: display,
                           modelGainPending: request.recipe.hdrSource.usesModel && !request.usesModelGain
                               && request.recipe.conditionValue("hdr.enabled")?.boolValue != false)
    }

    func effectMask(_ request: EditorRenderRequest, parameterID: String) async throws -> RenderMask {
        throw EditorRenderingError.unsupported("The fake draws no effect masks")
    }

    func sdrThumbnail(_ frame: EditorFrame, maximumSize: HyperDRRender.PixelSize) async throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.allocationFailed
        }
        context.setFillColor(gray: 0.46, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    func predictModelGain(modelID: String) async throws {
        predictions.append(modelID)
        if holdingPredictions {
            await withCheckedContinuation { heldPredictions.append($0) }
        }
        try Task.checkCancellation()
        switch modelBehavior {
        case .succeed: return
        case .fail(let reason): throw FakeFailure(reason: reason)
        case .unavailable(let reason): throw EditorRenderingError.modelUnavailable(reason)
        }
    }

    func installLUT(_ lut: ColorLUT) async {
        installedLUTs.insert(lut.contentHash)
    }

    func close() async {
        current = nil
    }

    struct FakeFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// An 8 × 8 mid grey with zero gain: enough for the canvas and the scopes to draw.
    private func makePlanes(size: HyperDRRender.PixelSize) throws -> RenderPlanes {
        if textures == nil {
            guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.metalUnavailable }
            func texture(_ format: MTLPixelFormat, fill: [Float]) throws -> any MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 8, height: 8,
                                                                          mipmapped: false)
                descriptor.usage = [.shaderRead]
                guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocationFailed }
                let components = fill.count
                let pixels = [Float]((0..<64).flatMap { _ in fill })
                pixels.withUnsafeBytes {
                    texture.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0,
                                    withBytes: $0.baseAddress!, bytesPerRow: 8 * components * 4)
                }
                return texture
            }
            textures = (try texture(.rgba32Float, fill: [0.18, 0.18, 0.18, 1]), try texture(.r32Float, fill: [0]))
        }
        let (base, gain) = textures!
        return RenderPlanes(base: base, gain: gain, baseColorSpace: RenderEngine.workingColorSpace,
                            provenance: .identity, region: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                            outputSize: size)
    }
}
#endif
