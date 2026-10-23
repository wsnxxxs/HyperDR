import CoreImage
import Foundation
import Metal
import Testing
@testable import HyperDRRender

private final class BitmapProcessorGate: NSObject, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let condition = NSCondition()
    private var released = false
    private let lock = NSLock()
    private var callsStorage = 0
    var calls: Int { lock.withLock { callsStorage } }
    func began() { lock.withLock { callsStorage += 1 }; started.signal() }
    func awaitStart() -> Bool { started.wait(timeout: .now() + 5) == .success }
    func releaseAll() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
    func awaitRelease() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: deadline) { return released }
        }
        return true
    }
}

/// A documented CPU image processor can fail without corrupting a GPU command.
/// Invocation state is passed through CI's arguments, never stored on the kernel.
private final class BitmapFailureProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }

    override class func process(with inputs: [any CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: any CIImageProcessorOutput) throws {
        guard let gate = arguments?["gate"] as? BitmapProcessorGate else {
            throw NSError(domain: "HyperDRBitmapProcessorTest", code: 71)
        }
        gate.began()
        if arguments?["fail"] as? Bool == true {
            throw NSError(domain: "HyperDRBitmapProcessorTest", code: 73,
                userInfo: [NSLocalizedDescriptionKey: "Controlled image processor failure"])
        }
        guard gate.awaitRelease() else {
            throw NSError(domain: "HyperDRBitmapProcessorTest", code: 74,
                userInfo: [NSLocalizedDescriptionKey: "Test processor release timed out"])
        }
        for y in 0..<Int(output.region.height) {
            let row = output.baseAddress.advanced(by: y * output.bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<Int(output.region.width) {
                row[x * 4] = 0.25; row[x * 4 + 1] = 0.5; row[x * 4 + 2] = 0.75; row[x * 4 + 3] = 1
            }
        }
    }
}

private struct BitmapTaskFailureObservation: Sendable {
    let stage, domain: String
    let code: Int
}

private extension RenderEngine {
    func bitmapTaskTestPixels(_ image: CIImage) throws -> [Float] {
        Self.readTexture(try rasterizeNativeRAW(image, space: Self.workingColorSpace))
    }

    /// Direct API control distinguishes startTask from wait errors without
    /// installing a hook in the renderer or altering its error mapping.
    func bitmapWaitFailureObservation(_ image: CIImage) throws -> BitmapTaskFailureObservation? {
        let bounds = image.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        let rowBytes = width * 16
        guard let bytes = device.makeBuffer(length: rowBytes * height, options: .storageModeShared) else {
            throw RenderError.allocationFailed
        }
        bytes.contents().initializeMemory(as: UInt8.self, repeating: 0, count: bytes.length)
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAf.rawValue, .outputPremultiplied: false,
            .cacheIntermediates: false, .memoryTarget: 256])
        let destination = CIRenderDestination(bitmapData: bytes.contents(), width: width, height: height,
            bytesPerRow: rowBytes, format: .RGBAf)
        destination.colorSpace = Self.workingColorSpace
        destination.alphaMode = .unpremultiplied
        destination.isFlipped = true
        var stage = "startTask"
        do {
            let task = try context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
            stage = "waitUntilCompleted"
            _ = try task.waitUntilCompleted()
            return nil
        } catch {
            let error = error as NSError
            return BitmapTaskFailureObservation(stage: stage, domain: error.domain, code: error.code)
        }
    }
}

@Suite(.serialized) struct RAWBitmapTaskErrorTests {
    @Test func aProcessorErrorEscapesTheBitmapTaskWithoutPublishingSentinelPixels() async throws {
        let engine = try RenderEngine()
        let bounds = CGRect(x: 37, y: 71, width: 64, height: 32)
        let healthy = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: bounds)
        let reference = try await engine.bitmapTaskTestPixels(healthy)
        let controlGate = BitmapProcessorGate()
        let controlImage = try BitmapFailureProcessor.apply(withExtent: bounds, inputs: nil,
            arguments: ["gate": controlGate, "fail": true])
        let control = try #require(await engine.bitmapWaitFailureObservation(controlImage))
        #expect(control.stage == "waitUntilCompleted" && controlGate.calls > 0,
                "The controlled NSError must be observed from the task's throwing wait")
        print("RAW_BITMAP_CONTROL_ERROR stage=\(control.stage) domain=\(control.domain) code=\(control.code)")
        let gate = BitmapProcessorGate()
        let image = try BitmapFailureProcessor.apply(withExtent: bounds, inputs: nil,
            arguments: ["gate": gate, "fail": true])
        do {
            _ = try await engine.bitmapTaskTestPixels(image)
            Issue.record("A failed CI processor published a RAW texture")
        } catch {
            // A task-reported processor error must retain its failure path; it
            // must not turn into the opacity retry's decoder-fallback signal.
            if case RenderError.cannotDecodeSource = error {
                Issue.record("CI task error was reclassified as an incomplete RAW decode")
            }
            #expect(gate.calls > 0, "The error must occur during actual CI processing")
            let nsError = error as NSError
            print("RAW_BITMAP_TASK_ERROR domain=\(nsError.domain) code=\(nsError.code) processorCalls=\(gate.calls)")
        }
        #expect(try await engine.bitmapTaskTestPixels(healthy) == reference,
                "A failed bitmap task poisoned a subsequent complete render")
    }

    @Test(arguments: [false, true])
    func aCancelledBitmapTaskNeverPublishesItsCompletedPixels(cancelBeforeStarting: Bool) async throws {
        let engine = try RenderEngine(), gate = BitmapProcessorGate()
        let image = try BitmapFailureProcessor.apply(withExtent: CGRect(x: 37, y: 71, width: 64, height: 32),
            inputs: nil, arguments: ["gate": gate, "fail": false])
        defer { gate.releaseAll() }
        let task = Task {
            if cancelBeforeStarting { withUnsafeCurrentTask { $0?.cancel() } }
            return try await engine.bitmapTaskTestPixels(image)
        }
        if !cancelBeforeStarting {
            let started = await Task.detached { gate.awaitStart() }.value
            if !started {
                task.cancel(); gate.releaseAll()
                _ = try? await task.value
                Issue.record("The controlled processor did not begin")
                return
            }
            task.cancel()
            gate.releaseAll()
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled bitmap render published pixels")
        } catch is CancellationError {
            #expect(cancelBeforeStarting ? gate.calls == 0 : gate.calls > 0)
        } catch {
            Issue.record("Expected CancellationError after controlled cancellation, received \(error)")
        }
        gate.releaseAll()
        let healthy = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 37, y: 71, width: 64, height: 32))
        let recovered = try await engine.bitmapTaskTestPixels(healthy)
        #expect(recovered.count == 64 * 32 * 4 && recovered.allSatisfy(\.isFinite))
        #expect(stride(from: 3, to: recovered.count, by: 4).allSatisfy { recovered[$0] == 1 },
                "A cancelled task must not poison a subsequent complete decode")
    }
}
