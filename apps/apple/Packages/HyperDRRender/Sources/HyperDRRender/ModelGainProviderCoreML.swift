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
/// The input is the SDR version of the photograph the user actually sees, at the
/// analysis scale, with values outside [0, 1] clamped by the feature builder
/// (the model's declared domain). Two entry points, one prediction:
///
/// * `predict(source:)` for an `sdr` source, whose SDR version is the oriented
///   source image itself.
/// * `prediction(forSDRBase:sourceID:size:)` for a `rawEDR` source, where the
///   graph hands over the base its source split produced. The system's
///   extended-range development is deliberately *not* used for AI: the model was
///   trained on ordinary SDR photographs, so clipping EDR output into [0, 1]
///   would move the input distribution away from what it learned.
///
/// Either way the base follows from the source alone, so the cache stays keyed by
/// `(sourceID, modelID)`; callers should use one entry point per source.
///
/// `modelID` carries the model version and the preprocessing revision as well as
/// the model name, so a cache keyed by `(sourceID, modelID)` is invalidated by a
/// re-conversion. Callers should create one provider and keep it: the model is
/// loaded once, and the last prediction is retained.
public final class CoreMLModelGainProvider: ModelGainProvider, @unchecked Sendable {
    /// Model identity for the graph's cache: model name, version, preprocessing
    /// revision and the analysis scale. The grid's *size* follows from the source
    /// and this scale, and the source is the other half of the key, so the two
    /// together identify the prediction — but two providers configured with
    /// different scales must not share an identity, because their grids differ.
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
        self.modelID = [model.modelIdentifier, model.version, ModelGain.preprocessingRevision,
                        "analysis-\(analysisLongSide)"].joined(separator: "/")
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: RenderEngine.workingColorSpace,
            .workingFormat: CIFormat.RGBAf.rawValue,
            .cacheIntermediates: false
        ])
    }

    /// Gain for a source whose SDR version is the source itself.
    public func predict(source: RenderSource) async throws -> ModelGainPrediction {
        try await offCaller { try self.predict(source: source) }
    }

    /// Gain for an explicit SDR base — the version of the photograph the user
    /// actually sees, which for a `rawEDR` source is the base its source split
    /// produced rather than the extended-range development.
    ///
    /// `base` is expected to be in the working space (linear extended Display P3)
    /// and to carry the source orientation, exactly like `RenderSource.hdrImage`.
    /// `size` is the base's pixel size, from which the analysis grid follows.
    public func prediction(forSDRBase base: CIImage, sourceID: UUID,
                          size: PixelSize) async throws -> ModelGainPrediction {
        try await offCaller { try self.infer(base: base, sourceID: sourceID, size: size) }
    }

    private func offCaller(_ work: @escaping @Sendable () throws -> ModelGainPrediction) async throws -> ModelGainPrediction {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func predict(source: RenderSource) throws -> ModelGainPrediction {
        // Only SDR and RAW sources choose an AI HDR source; an authored HDR or
        // dual-rendition photograph already carries its gain map.
        switch source.domain {
        case .sdr:
            // The materialized source texture is already in the working space at
            // full resolution, so the analysis reduction reads it directly.
            return try infer(texture: source.texture, sourceID: source.id, size: source.size)
        case .rawEDR:
            // The extended-range development is not the picture the model was
            // trained on. The graph knows the SDR base and passes it explicitly.
            throw ModelGainError.unsupportedSource(
                "a RAW source needs its SDR base; call prediction(forSDRBase:sourceID:size:)")
        case .hdr, .dual:
            throw ModelGainError.unsupportedSource(
                "AI gain applies to SDR and RAW sources; this source is \(source.domain.rawValue)")
        }
    }

    private func infer(texture: any MTLTexture, sourceID: UUID,
                       size: PixelSize) throws -> ModelGainPrediction {
        try infer(sourceID: sourceID, size: size) { tensor in
            try ModelGainInput.features(from: texture, tensorSize: tensor, device: self.device)
        }
    }

    private func infer(base: CIImage, sourceID: UUID,
                       size: PixelSize) throws -> ModelGainPrediction {
        try infer(sourceID: sourceID, size: size) { tensor in
            try ModelGainInput.features(from: base, context: self.context, tensorSize: tensor,
                                       device: self.device)
        }
    }

    private func infer(sourceID: UUID, size: PixelSize,
                       features build: (PixelSize) throws -> ModelGainFeatures) throws -> ModelGainPrediction {
        let tensor = ModelGain.tensorSize(for: size, longSide: analysisLongSide)
        if let cached, cached.sourceID == sourceID, cached.tensor == tensor {
            return cached.prediction
        }
        let features = try build(tensor)
        let grid = try model.gain(for: features)
        let texture = try makeTexture(grid)
        let prediction = ModelGainPrediction(sourceID: sourceID, modelID: modelID, gain: texture)
        cached = (sourceID, tensor, prediction)
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
