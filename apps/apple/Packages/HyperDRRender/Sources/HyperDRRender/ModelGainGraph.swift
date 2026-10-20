import Foundation
import CoreImage
import Metal

extension ModelGainPrediction: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.sourceID == rhs.sourceID && lhs.modelID == rhs.modelID }
    public func hash(into hasher: inout Hasher) { hasher.combine(sourceID); hasher.combine(modelID) }
}
struct ModelPredictionKey: Equatable { let source: UUID; let model: String }
struct ModelFilterKey: Equatable { let prediction: ModelPredictionKey; let start: Float? }

extension RenderEngine {
    /// Start inference outside the synchronous render path, then inject the returned
    /// prediction through render(recipe:modelGain:). Before it arrives, aiPending is true.
    public func predictModelGain(_ source: RenderSource, provider: CoreMLModelGainProvider) async throws -> ModelGainPrediction {
        guard source.domain == .sdr || source.domain == .rawEDR else { throw RenderError.invalidAdjustment }
        let key = ModelPredictionKey(source:source.id,model:provider.modelID)
        if let cache = modelPredictionCache, cache.key == key { return cache.value }
        let prediction: ModelGainPrediction
        if source.domain == .sdr { prediction = try await provider.predict(source:source) }
        else {
            prediction = try await provider.prediction(forSDRBase:sdrBase(source),sourceID:source.id,size:source.size)
        }
        try Task.checkCancellation()
        guard prediction.sourceID == key.source, prediction.modelID == key.model else { throw RenderError.invalidAdjustment }
        modelPredictionCache = (key,prediction)
        return prediction
    }

    /// The unedited source separation, with zero SDR highlight rolloff. No recipe
    /// or HDR controls can alter the image the RAW model sees.
    public func sdrBase(_ source: RenderSource) throws -> CIImage {
        guard source.domain == .sdr || source.domain == .rawEDR else { throw RenderError.invalidAdjustment }
        let planes = try render(source)
        guard let image = CIImage(mtlTexture:planes.base,options:[.colorSpace:Self.workingColorSpace]) else {
            throw RenderError.cannotDecodeSource
        }
        return image.transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:image.extent.height))
    }

    func filteredModelGain(_ source: RenderSource, edit: RenderAdjustments) throws -> (gain: any MTLTexture, peak: Float)? {
        guard (edit.hdr.source ?? .defaultSource(for:source.domain)).usesModel,
              edit.hdr.enabled, let prediction = edit.hdr.modelGain else { return nil }
        guard prediction.sourceID == source.id, prediction.gain.pixelFormat == .r32Float else { throw RenderError.invalidAdjustment }
        let key = ModelFilterKey(prediction:ModelPredictionKey(source:source.id,model:prediction.modelID),start:edit.hdr.expansionStart)
        if let cache = modelFilterCache, cache.key == key { return (cache.gain,cache.peak) }
        // Guide and inference both describe the untouched photograph. Tone/LUT
        // edits cannot rerun inference or change this guided reconstruction.
        let analysis = try self.analysis(source)
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let node = nodeContext(domain:source.domain,buffer:command)
        let w = analysis.size.width, h = analysis.size.height
        func texture(_ format: MTLPixelFormat = .rgba32Float) throws -> any MTLTexture {
            try node.texture(width:w,height:h,format:format)
        }
        let weights = try texture(), temp = try texture(), means = try texture()
        let coefficients = try texture(), smoothed = try texture(), gain = try texture(.r32Float)
        var start = edit.hdr.expansionStart ?? -1
        try node.dispatch("modelGainWeights",width:w,height:h,textures:[analysis.cells,prediction.gain,weights],value:&start)
        func box(_ input: any MTLTexture, _ output: any MTLTexture) throws {
            var p = BoxUniform(radius:UInt32(min(8,max(4,min(w,h)/96))),vertical:0,width:UInt32(w),height:UInt32(h))
            try node.dispatch("graphBox",width:w,height:h,textures:[input,temp],value:&p)
            p.vertical = 1
            try node.dispatch("graphBox",width:w,height:h,textures:[temp,output],value:&p)
        }
        try box(weights,means)
        var unused: UInt32 = 0
        try node.dispatch("graphCoefficients",width:w,height:h,textures:[means,coefficients],value:&unused)
        try box(coefficients,smoothed)
        try node.dispatch("graphFinalGain",width:w,height:h,textures:[analysis.cells,smoothed,weights,gain],value:&unused)
        guard let peak = device.makeBuffer(length:4,options:.storageModeShared) else { throw RenderError.allocationFailed }
        peak.contents().storeBytes(of:UInt32(0),as:UInt32.self)
        var channels: UInt32 = 1
        try node.dispatch("displayGainPeak",width:w,height:h,textures:[gain],buffers:[peak],value:&channels)
        try finish(command)
        let maximum = Float(bitPattern:peak.contents().load(as:UInt32.self))
        modelFilterCache = (key,gain,maximum)
        return (gain,maximum)
    }
}
