import HyperDREngine
import Metal

/// Opt-in counter sampling in the existing command buffer: no extra buffer,
/// semaphore, readback wait, or main-thread GPU operation is introduced.
nonisolated enum PreviewGPUTiming {
    static func encoder(device: any MTLDevice, command: any MTLCommandBuffer,
                        trace: PreviewTrace?, enabled: Bool = PreviewTrace.recordsEnabled,
                        onInterval: (@Sendable (UInt64, UInt64) -> Void)? = nil) -> (any MTLComputeCommandEncoder)? {
        guard enabled, let trace else { return command.makeComputeCommandEncoder() }
        guard device.supportsCounterSampling(.atStageBoundary),
              let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else {
            trace.record("pass1_gpu", "unavailable")
            return command.makeComputeCommandEncoder()
        }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = set; descriptor.sampleCount = 2; descriptor.storageMode = .shared
        guard let samples = try? device.makeCounterSampleBuffer(descriptor: descriptor) else {
            trace.record("pass1_gpu", "unavailable")
            return command.makeComputeCommandEncoder()
        }
        let pass = MTLComputePassDescriptor()
        pass.sampleBufferAttachments[0].sampleBuffer = samples
        pass.sampleBufferAttachments[0].startOfEncoderSampleIndex = 0
        pass.sampleBufferAttachments[0].endOfEncoderSampleIndex = 1
        let before = device.sampleTimestamps()
        command.addCompletedHandler { completed in
            let after = device.sampleTimestamps()
            guard completed.status == .completed, after.gpu > before.gpu, after.cpu > before.cpu,
                  let data = try? samples.resolveCounterRange(0..<2), data.count >= 2 * MemoryLayout<MTLCounterResultTimestamp>.stride else {
                trace.record("pass1_gpu", "unavailable"); return
            }
            let values = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)) }
            let start = values[0].timestamp, end = values[1].timestamp
            guard start != MTLCounterErrorValue, end != MTLCounterErrorValue, end >= start, start >= before.gpu else {
                trace.record("pass1_gpu", "unavailable"); return
            }
            let scale = Double(after.cpu - before.cpu) / Double(after.gpu - before.gpu)
            let cpuStart = before.cpu + UInt64(Double(start - before.gpu) * scale)
            let cpuEnd = before.cpu + UInt64(Double(end - before.gpu) * scale)
            trace.gpuInterval(start: cpuStart, end: cpuEnd)
            onInterval?(cpuStart, cpuEnd)
        }
        return command.makeComputeCommandEncoder(descriptor: pass)
    }
}
