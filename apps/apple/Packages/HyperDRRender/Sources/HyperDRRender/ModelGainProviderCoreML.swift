import Foundation
import CoreImage
import CoreML
import Metal

/// The Core ML implementation of `ModelGainProvider`.
///
/// The AI gain is a property of the original photograph: it is inferred once from
/// the oriented linear-P3 source at a fixed analysis scale, cached, and reused by
/// every tone, colour, LUT or stripe pass. This type therefore sees a
/// `RenderSource` and nothing else — it has no access to adjustments, which is
/// what makes that property structural rather than a convention.
///
/// The prediction is a single-channel `r32Float` texture holding the model's
/// stride-16 grid, one cell per 16 × 16 base pixels, rows top-down, values in
/// signed log2 stops. Its size is the grid size (`ModelGain.gridSize`), so the
/// consumer derives sampling from the texture itself; nothing here upscales to
/// the base, and no offsets are attached (our own separations carry zero
/// offsets). Strength, range, rolloff and expansion start are applied after
/// prediction, by the graph.
///
/// The base it reads is `RenderSource.hdrImage` — the oriented source in the
/// working space — resampled to the analysis scale. Values outside [0, 1] are
/// clamped by the feature builder, which is the model's declared domain. For a
/// RAW source that input is the system's extended-range development, not the
/// engine's tone-mapped SDR base; if the graph wants the latter for AI, it should
/// hand this type that image rather than redeveloping it here.
///
/// `modelID` carries the model version and the preprocessing revision as well as
/// the model name, so a cache keyed by `(sourceID, modelID)` is invalidated by a
/// re-conversion. Callers should create one provider and keep it: the model is
/// loaded once, and the last prediction is retained.
public final class CoreMLModelGainProvider: ModelGainProvider, @unchecked Sendable {
    /// Model identity for the graph's cache: model name, version, preprocessing
    /// revision. The analysis grid follows from the source, so it is not repeated.
    public let modelID: String
    public let analysisLongSide: Int
    private let model: ModelGainModel
    private let context: CIContext
    private let device: any MTLDevice
    /// All model and cache access is serialized here, which keeps inference off
    /// the caller's actor and off the cooperative pool.
    private let queue = DispatchQueue(label: "hyperdr.modelgain.coreml", qos: .userInitiated)
    private var cached: (sourceID: UUID, tensor: PixelSize, prediction: ModelGainPrediction)?

    public init(computeUnits: MLComputeUnits = .all,
                device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
                analysisLongSide: Int = ModelGain.analysisLongSide,
                bundle: Bundle? = nil) throws {
        guard let device else { throw RenderError.metalUnavailable }
        let model = try ModelGainModel(computeUnits: computeUnits, bundle: bundle)
        self.device = device
        self.model = model
        self.analysisLongSide = analysisLongSide
        self.modelID = "\(model.modelIdentifier)/\(model.version)/\(ModelGain.preprocessingRevision)"
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: RenderEngine.workingColorSpace,
            .workingFormat: CIFormat.RGBAf.rawValue,
            .cacheIntermediates: false
        ])
    }

    public func predict(source: RenderSource) async throws -> ModelGainPrediction {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.predictSynchronously(source) })
            }
        }
    }

    private func predictSynchronously(_ source: RenderSource) throws -> ModelGainPrediction {
        // Only SDR and RAW sources choose an AI HDR source; an authored HDR or
        // dual-rendition photograph already carries its gain map.
        switch source.domain {
        case .sdr, .rawEDR:
            break
        case .hdr, .dual:
            throw ModelGainError.unsupportedSource(
                "AI gain applies to SDR and RAW sources; this source is \(source.domain.rawValue)")
        }
        let tensor = ModelGain.tensorSize(for: source.size, longSide: analysisLongSide)
        if let cached, cached.sourceID == source.id, cached.tensor == tensor {
            return cached.prediction
        }
        let features = try ModelGainInput.features(from: source.hdrImage, context: context,
                                                   tensorSize: tensor)
        let grid = try model.gain(for: features)
        let texture = try makeTexture(grid)
        let prediction = ModelGainPrediction(sourceID: source.id, modelID: modelID, gain: texture)
        cached = (source.id, tensor, prediction)
        return prediction
    }

    private func makeTexture(_ grid: ModelGainGrid) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
            width: grid.size.width, height: grid.size.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.allocationFailed
        }
        grid.log2Stops.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, grid.size.width, grid.size.height),
                            mipmapLevel: 0, withBytes: bytes.baseAddress!,
                            bytesPerRow: grid.size.width * MemoryLayout<Float>.size)
        }
        return texture
    }
}
