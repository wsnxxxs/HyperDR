import Foundation
import CoreImage
import CoreML
import ImageIO
import Metal
import Testing
import HyperDRRecipe
@testable import HyperDRRender

/// The gate the AI gain model has to pass before it can replace ncnn.
///
/// The reference grids in `Fixtures/ModelGain` were produced by the shipped ncnn
/// path (`HyperDR model-gain --input-tensor`, see
/// `HyperDR_Model/scripts/make_coreml_tolerance_fixtures.py`) on the very same
/// stored inputs, so a difference here is a difference between the two backends,
/// not between two sets of test data.
private enum Gate {
    /// A tenth of a stop is invisible in the shadow of a JPEG's own tolerance;
    /// p99.9 catches a scale or offset error that a per-pixel maximum can hide.
    static let maximumStops: Float = 0.1
    static let p999Stops: Float = 0.02
}

private struct ReferenceCase: Sendable {
    let name: String
    let kind: String
    let width: Int
    let height: Int
    let gridWidth: Int
    let gridHeight: Int
    let upsampledBy: Int?
    let upsampledGridWidth: Int?
    let upsampledGridHeight: Int?

    var sourceURL: URL { Fixture.directory.appendingPathComponent("\(name).png") }
    var gainURL: URL { Fixture.directory.appendingPathComponent("\(name).ncnn.f32") }
}

private enum Fixture {
    static let directory: URL = {
        guard let url = Bundle.module.url(forResource: "ModelGain", withExtension: nil,
                                         subdirectory: "Fixtures") else {
            fatalError("Fixtures/ModelGain is missing from the test bundle")
        }
        return url
    }()

    static func cases() throws -> [ReferenceCase] {
        let data = try Data(contentsOf: directory.appendingPathComponent("cases.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let entries = object["cases"] as? [[String: Any]] ?? []
        return try entries.map { entry in
            func value(_ key: String) throws -> [Int] {
                guard let numbers = entry[key] as? [NSNumber] else {
                    throw ModelGainError.invalidTensorSize(PixelSize(width: 0, height: 0))
                }
                return numbers.map(\.intValue)
            }
            let tensor = try value("tensor")
            let grid = try value("grid")
            let upsampledBy = (entry["upsampledBy"] as? NSNumber)?.intValue
            let upsampled = (entry["upsampledGrid"] as? [NSNumber])?.map(\.intValue)
            return ReferenceCase(name: entry["name"] as? String ?? "?",
                                 kind: entry["kind"] as? String ?? "?",
                                 width: tensor[1], height: tensor[0],
                                 gridWidth: grid[1], gridHeight: grid[0],
                                 upsampledBy: upsampledBy,
                                 upsampledGridWidth: upsampled?[1],
                                 upsampledGridHeight: upsampled?[0])
        }
    }

    /// Decodes the stored 8-bit sRGB base into linear floats, top-down.
    ///
    /// The sRGB transfer function is applied here rather than by the colour
    /// machinery: the stored file is untagged, and both sides of the comparison
    /// must decode the same bytes the same way.
    static func linearBase(_ url: URL) throws -> (rgb: [Float], size: PixelSize) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ModelGainError.modelUnavailable("cannot read \(url.lastPathComponent)")
        }
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ModelGainError.predictionFailed("no sRGB colour space")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ModelGainError.predictionFailed("cannot decode \(url.lastPathComponent)") }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                let value = Double(bytes[index * 4 + channel]) / 255
                let linear = value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                rgb[index * 3 + channel] = Float(linear)
            }
        }
        return (rgb, PixelSize(width: width, height: height))
    }

    static func gain(_ url: URL, width: Int, height: Int) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let count = width * height
        guard data.count == count * MemoryLayout<Float>.size else {
            throw ModelGainError.invalidInputCount(expected: count, actual: data.count / 4)
        }
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }
}

private struct Difference: CustomStringConvertible {
    let maximum: Float
    let p999: Float
    let mean: Float
    let signedMean: Float

    init(lhs: [Float], rhs: [Float]) {
        precondition(lhs.count == rhs.count && !lhs.isEmpty)
        var differences = [Float](repeating: 0, count: lhs.count)
        var signed: Float = 0
        for index in 0..<lhs.count {
            differences[index] = abs(lhs[index] - rhs[index])
            signed += lhs[index] - rhs[index]
        }
        differences.sort()
        maximum = differences[differences.count - 1]
        let rank = max(1, Int((Double(differences.count) * 0.999).rounded(.up)))
        p999 = differences[min(differences.count - 1, rank - 1)]
        mean = differences.reduce(0, +) / Float(differences.count)
        signedMean = signed / Float(lhs.count)
    }

    var description: String {
        String(format: "max %.5f p99.9 %.5f mean|d| %.5f mean(d) %+.5f stops",
               maximum, p999, mean, signedMean)
    }
}

@Suite(.serialized) struct ModelGainTests {
    private func model(_ units: MLComputeUnits) throws -> ModelGainModel {
        try ModelGainModel(computeUnits: units)
    }

    /// ncnn parity at the compute units that ship and, separately, on the CPU.
    ///
    /// Both runs see identical input bytes; the only difference between them is
    /// where Core ML schedules the program.
    @Test(arguments: [MLComputeUnits.all, .cpuOnly])
    func ncnnParity(units: MLComputeUnits) throws {
        let model = try model(units)
        var covered = 0
        for reference in try Fixture.cases() {
            let (rgb, size) = try Fixture.linearBase(reference.sourceURL)
            #expect(size.width == reference.width && size.height == reference.height)
            let features = try ModelGainFeatures.make(linearP3RGB: rgb, size: size)
            let grid = try model.gain(for: features)
            #expect(grid.size == PixelSize(width: reference.gridWidth, height: reference.gridHeight))
            let expected = try Fixture.gain(reference.gainURL,
                                            width: reference.gridWidth, height: reference.gridHeight)
            let difference = Difference(lhs: grid.log2Stops, rhs: expected)
            #expect(difference.p999 <= Gate.p999Stops,
                    "\(reference.name) (\(reference.kind)) at \(units): \(difference)")
            #expect(difference.maximum <= Gate.maximumStops,
                    "\(reference.name) (\(reference.kind)) at \(units): \(difference)")
            covered += grid.log2Stops.count
            print("model gain parity \(reference.name) @\(units): \(difference)")

            guard let factor = reference.upsampledBy,
                  let width = reference.upsampledGridWidth,
                  let height = reference.upsampledGridHeight else { continue }
            // Nearest-neighbour replication is exact in both languages, so the
            // analysis-scale case needs no second stored image.
            let scaled = Self.upsampled(rgb, width: size.width, height: size.height, factor: factor)
            let scaledSize = PixelSize(width: size.width * factor, height: size.height * factor)
            let scaledGrid = try model.gain(for: ModelGainFeatures.make(linearP3RGB: scaled, size: scaledSize))
            #expect(scaledGrid.size == PixelSize(width: width, height: height))
            let scaledExpected = try Fixture.gain(
                Fixture.directory.appendingPathComponent("\(reference.name)-x\(factor).ncnn.f32"),
                width: width, height: height)
            let scaledDifference = Difference(lhs: scaledGrid.log2Stops, rhs: scaledExpected)
            #expect(scaledDifference.p999 <= Gate.p999Stops,
                    "\(reference.name) x\(factor) at \(units): \(scaledDifference)")
            #expect(scaledDifference.maximum <= Gate.maximumStops,
                    "\(reference.name) x\(factor) at \(units): \(scaledDifference)")
            covered += scaledGrid.log2Stops.count
            print("model gain parity \(reference.name) x\(factor) @\(units): \(scaledDifference)")
        }
        // Guards against a case list that quietly emptied out.
        #expect(covered >= 1500)
    }

    /// Analysis geometry is the engine's: capped scale, stride-16 rounding.
    @Test func analysisSizeMatchesTheEngine() {
        #expect(ModelGain.tensorSize(for: PixelSize(width: 9504, height: 6336))
                == PixelSize(width: 1024, height: 688))
        #expect(ModelGain.tensorSize(for: PixelSize(width: 6336, height: 9504))
                == PixelSize(width: 688, height: 1024))
        #expect(ModelGain.tensorSize(for: PixelSize(width: 4000, height: 3000))
                == PixelSize(width: 1024, height: 768))
        // A photograph smaller than the analysis scale is not upsampled, and the
        // stride rounding still applies.
        #expect(ModelGain.tensorSize(for: PixelSize(width: 200, height: 130))
                == PixelSize(width: 208, height: 144))
        #expect(ModelGain.gridSize(for: PixelSize(width: 1024, height: 688))
                == PixelSize(width: 64, height: 43))
    }

    /// The feature planes are the frozen contract, not an approximation of it.
    @Test func featurePlanesFollowTheContract() throws {
        // White: full log luminance and the clipping flag set.
        // 0.18 grey: log luminance ((log2(0.18) + 12) / 12).
        // Black: log luminance clamped to 0.
        let size = PixelSize(width: 16, height: 16)
        let rgb: [Float] = [1, 1, 1, 0.18, 0.18, 0.18, 0, 0, 0] + [Float](repeating: 0,
                                                                            count: (256 - 3) * 3)
        let features = try ModelGainFeatures.make(linearP3RGB: rgb, size: size)
        let pixels = size.width * size.height
        #expect(features.planes[0] == 1)
        #expect(features.planes[pixels * 3] == 1)
        #expect(features.planes[pixels * 4] == 1)
        let grey = (log2(Float(0.18)) + 12) / 12
        #expect(abs(features.planes[pixels * 3 + 1] - grey) < 1.0e-6)
        #expect(features.planes[pixels * 4 + 1] == 0)
        #expect(features.planes[pixels * 3 + 2] == 0)
    }

    /// A base keeps its top-down row order through the analysis rasterization.
    ///
    /// The source image here is a CGImage, whose first scanline is the top of the
    /// picture, exactly like an ImageIO-decoded photograph. A swapped row order
    /// would put the bright half in the wrong end of the feature planes and, from
    /// there, in the wrong end of the gain grid.
    @Test func imageInputKeepsOrientation() throws {
        let width = 256, height = 192
        let top = [UInt8](repeating: 128, count: width * height / 2 * 3)  // mid grey
        var bottom = [UInt8](repeating: 0, count: width * height / 2 * 3)
        for index in stride(from: 1, to: bottom.count, by: 3) { bottom[index] = 12 }
        let bytes = top + bottom
        let cgImage = try #require(Self.cgImage(rgb8: bytes, width: width, height: height))
        let context = try #require(Self.context())
        let size = PixelSize(width: width, height: height)
        let features = try ModelGainInput.features(from: CIImage(cgImage: cgImage),
                                                   context: context, tensorSize: size)
        let pixels = size.width * size.height
        let logLuminance = { (row: Int) in
            features.planes[pixels * 3 + row * size.width + size.width / 2]
        }
        #expect(logLuminance(size.height / 4) > logLuminance(size.height * 3 / 4) + 0.2)
        // The one-call convenience reaches the same grid as the two-step path.
        let model = try ModelGainModel(computeUnits: .all)
        let grid = try model.gain(from: CIImage(cgImage: cgImage), context: context, sourceSize: size)
        #expect(grid.size == ModelGain.gridSize(for: size))
        #expect(try model.gain(for: features).log2Stops == grid.log2Stops)
    }

    /// A texture reaches the same features as the image it was rendered from.
    @Test func textureInputMatchesImageInput() throws {
        let width = 128, height = 96
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 3
                let bright = y < height / 3
                bytes[index] = bright ? 200 : 40
                bytes[index + 1] = bright ? 170 : 30
                bytes[index + 2] = 120
            }
        }
        let cgImage = try #require(Self.cgImage(rgb8: bytes, width: width, height: height))
        let image = CIImage(cgImage: cgImage)
        let context = try #require(Self.context())
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        // Written the way RenderEngine writes its planes: one flip, so texture row
        // 0 is the top of the picture.
        let topDown = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                             tx: 0, ty: CGFloat(height)))
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = RenderEngine.workingColorSpace
        destination.alphaMode = .unpremultiplied
        _ = try context.startTask(toRender: topDown, to: destination)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let size = PixelSize(width: 128, height: 96)
        let fromImage = try ModelGainInput.features(from: image, context: context, tensorSize: size)
        let fromTexture = try ModelGainInput.features(from: texture, context: context, tensorSize: size)
        let difference = Difference(lhs: fromImage.planes, rhs: fromTexture.planes)
        #expect(difference.maximum < 0.0005, "texture and image features differ: \(difference)")
        // And the bright band really is at the top of both.
        let pixels = size.width * size.height
        let logLuminance = { (row: Int) in fromTexture.planes[pixels * 3 + row * size.width + size.width / 2] }
        #expect(logLuminance(4) > logLuminance(size.height - 4) + 0.15)
    }

    private static func context() -> CIContext? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return CIContext(mtlDevice: device, options: [
            .workingColorSpace: RenderEngine.workingColorSpace,
            .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
    }

    private static func cgImage(rgb8: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgb8) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: width * 3, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// The cached gain must not outlive the model identity it was computed with.
    @Test func cacheKeyCoversModelAndGrid() throws {
        let all = try model(.all)
        let cpu = try model(.cpuOnly)
        let size = PixelSize(width: 256, height: 192)
        #expect(all.identityKey == cpu.identityKey)
        #expect(all.identityKey.contains(all.version))
        #expect(all.identityKey.contains(ModelGain.preprocessingRevision))
        #expect(all.cacheKey(tensorSize: size) != all.cacheKey(tensorSize: PixelSize(width: 16, height: 16)))
        let features = try ModelGainFeatures.make(
            linearP3RGB: [Float](repeating: 0.5, count: size.width * size.height * 3), size: size)
        #expect(all.cacheKey(for: features) == all.cacheKey(tensorSize: size))
    }

    /// Inference cost at the production analysis scale, measured once.
    ///
    /// No tight bound: this exists to record the number and to fail loudly if the
    /// model ever starts spilling to something pathological (a flexible-shape
    /// recompile per call, for instance). AI gain runs once per photograph.
    @Test func analysisScaleInferenceCost() throws {
        let reference = try #require(try Fixture.cases().first { $0.upsampledBy != nil })
        let (rgb, size) = try Fixture.linearBase(reference.sourceURL)
        let factor = try #require(reference.upsampledBy)
        let scaled = Self.upsampled(rgb, width: size.width, height: size.height, factor: factor)
        let scaledSize = PixelSize(width: size.width * factor, height: size.height * factor)
        let features = try ModelGainFeatures.make(linearP3RGB: scaled, size: scaledSize)
        for units in [MLComputeUnits.all, .cpuOnly] {
            let model = try model(units)
            _ = try model.gain(for: features)  // warm-up, includes specialization
            let runs = 5
            let start = Date()
            for _ in 0..<runs { _ = try model.gain(for: features) }
            let milliseconds = Date().timeIntervalSince(start) * 1000 / Double(runs)
            print(String(format: "model gain %dx%d @%@: %.1f ms", scaledSize.width, scaledSize.height,
                         String(describing: units), milliseconds))
            #expect(milliseconds < 2000)
        }
    }

    /// The provider render-dev's graph calls: one prediction per source, a
    /// single-channel stop grid as a texture, and the model identity it should
    /// cache under.
    @Test func coreMLProviderCarriesTheModelGrid() async throws {
        let engine = try RenderEngine()
        let width = 384, height = 256
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 3
                bytes[index] = UInt8(40 + 120 * y / height)
                bytes[index + 1] = UInt8(30 + 160 * x / width)
                bytes[index + 2] = UInt8(200 - 120 * y / height)
            }
        }
        let cgImage = try #require(Self.cgImage(rgb8: bytes, width: width, height: height))
        let source = try await engine.source(image: CIImage(cgImage: cgImage), domain: .sdr)
        let provider = try CoreMLModelGainProvider()
        let prediction = try await provider.predict(source: source)

        #expect(prediction.sourceID == source.id)
        #expect(prediction.modelID.contains(ModelGain.modelName))
        #expect(prediction.modelID.contains(ModelGain.preprocessingRevision))
        #expect(prediction.modelID.contains(ModelGain.modelVersion))

        let tensor = ModelGain.tensorSize(for: source.size)
        #expect(tensor == PixelSize(width: 384, height: 256))
        #expect(prediction.gain.width == ModelGain.gridSize(for: tensor).width)
        #expect(prediction.gain.height == ModelGain.gridSize(for: tensor).height)

        // The texture carries exactly the grid the model predicted for this base.
        let context = try #require(Self.context())
        let grid = try ModelGainModel(computeUnits: .all).gain(for: ModelGainInput.features(
            from: source.hdrImage, context: context, tensorSize: tensor))
        let readback = RenderEngine.readTexture(prediction.gain)
        #expect(readback.count == grid.log2Stops.count)
        let difference = Difference(lhs: readback, rhs: grid.log2Stops)
        #expect(difference.maximum < 0.0001, "provider texture differs from the model grid: \(difference)")
        #expect(prediction.gain.pixelFormat == .r32Float)

        // Inference runs once per source; the second call returns the same grid.
        let repeated = try await provider.predict(source: source)
        #expect(repeated.gain === prediction.gain)
    }

    /// Only SDR and RAW sources choose an AI HDR source.
    @Test func coreMLProviderRefusesAuthoredHDR() async throws {
        let engine = try RenderEngine()
        let cgImage = try #require(Self.cgImage(rgb8: [UInt8](repeating: 120, count: 64 * 64 * 3),
                                                width: 64, height: 64))
        let source = try await engine.source(image: CIImage(cgImage: cgImage), domain: .hdr)
        let provider = try CoreMLModelGainProvider()
        do {
            _ = try await provider.predict(source: source)
            Issue.record("an authored HDR source must not get an AI gain")
        } catch {
            #expect(error is ModelGainError)
        }
    }

    private static func upsampled(_ rgb: [Float], width: Int, height: Int, factor: Int) -> [Float] {
        let scaledWidth = width * factor, scaledHeight = height * factor
        var result = [Float](repeating: 0, count: scaledWidth * scaledHeight * 3)
        for y in 0..<scaledHeight {
            let sourceRow = (y / factor) * width
            for x in 0..<scaledWidth {
                let source = (sourceRow + x / factor) * 3
                let target = (y * scaledWidth + x) * 3
                result[target] = rgb[source]
                result[target + 1] = rgb[source + 1]
                result[target + 2] = rgb[source + 2]
            }
        }
        return result
    }
}
