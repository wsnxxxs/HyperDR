import Foundation
import Metal

/// P7-1b integration boundary. Predictions are computed once from the original
/// oriented linear-P3 source, independent of tone/color/LUT settings. Gain is a
/// single-channel float log2-stop grid, not quantized codes or alpha.
public struct ModelGainPrediction: @unchecked Sendable {
    public let sourceID: UUID
    public let modelID: String
    public let gain: any MTLTexture
    public init(sourceID: UUID, modelID: String, gain: any MTLTexture) {
        self.sourceID = sourceID; self.modelID = modelID; self.gain = gain
    }
}

public protocol ModelGainProvider: Sendable {
    func predict(source: RenderSource) async throws -> ModelGainPrediction
}
