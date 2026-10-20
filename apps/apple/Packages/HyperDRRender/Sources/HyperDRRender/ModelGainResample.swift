import Foundation
import CoreImage
import Metal

/// Equal-area analysis scaling, matching the engine's resample policy.
///
/// The model saw photographs that the ncnn path had shrunk with
/// `hyperdr::resample_to` (`modules/image/src/resample.cpp`): repeated exact
/// 2 × 2 area halvings while a dimension is more than twice its target, then one
/// equal-area stage whose output pixels integrate a uniform footprint of the
/// input, with fractional weights on the partly covered edge pixels. A plain
/// affine scale is not that — it point-samples, so a 1.5× reduction of an
/// alternating 0/1 column pattern gives 0.75/0.25 instead of 2/3, 1/3 — and the
/// analysis image would no longer be the kind of picture the network was trained
/// on.
///
/// The same filter is reproduced here on the GPU in one pass: each destination
/// pixel reads the source pixels its staged footprint covers with the composed
/// weights. Because a footprint can span a few pixels per axis, and the source may
/// be far larger than the destination, the source is either read directly from an
/// already materialized texture or rendered and filtered one band of rows at a
/// time — never read back to the CPU as a whole frame.
public final class ModelGainResampler: @unchecked Sendable {
    /// Per-output-pixel tap table for one axis.
    struct AxisWeights {
        /// First source index and tap count for each output index.
        let first: [Int32]
        let count: [Int32]
        /// `count` weights per output index, `taps` apart.
        let weights: [Float]
        let taps: Int
    }

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    /// Row budget for the band-by-band path: about 32 MB of RGBA32Float source.
    private static let bandBudgetBytes = 32 * 1024 * 1024

    public init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RenderError.metalUnavailable }
        self.queue = queue
        // Xcode compiles the .metal file into the bundle's default library; a
        // plain SwiftPM build copies it as a resource instead. Either route ends
        // in the same function, so both are accepted.
        var library = (try? device.makeDefaultLibrary(bundle: Bundle.module))
            .flatMap { $0.makeFunction(name: "modelGainAnalysisAverage") == nil ? nil : $0 }
        if library == nil,
           let url = Bundle.module.url(forResource: "ModelGainAnalysis", withExtension: "metal") {
            let options = MTLCompileOptions()
            // The kernel is an average: relaxed math could reorder or approximate it.
            options.mathMode = .safe
            let compiled = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8),
                                                 options: options)
            library = compiled.makeFunction(name: "modelGainAnalysisAverage") == nil ? nil : compiled
        }
        guard let library, let function = library.makeFunction(name: "modelGainAnalysisAverage") else {
            throw RenderError.gpu("modelGainAnalysisAverage is not in the bundle")
        }
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Scales an already materialized source texture (top-down, RGBA32Float, in
    /// the working space) in one pass.
    public func resize(_ source: any MTLTexture, to size: PixelSize) throws -> any MTLTexture {
        let destination = try makeDestination(size)
        try Task.checkCancellation()
        guard let buffer = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let tables = Self.tables(source: PixelSize(width: source.width, height: source.height),
                                 destination: size)
        try encode(source: source, destination: destination,
                   tables: Tables(x: tables.x, y: tables.y, destinationRows: 0..<size.height),
                   sourceOrigin: (0, 0), destinationOriginY: 0, buffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else {
            throw RenderError.gpu(buffer.error?.localizedDescription ?? "analysis scaling failed")
        }
        return destination
    }

    /// Scales a Core Image base, rendering it in bands so a 61-megapixel source
    /// never has to exist as one texture.
    public func resize(_ image: CIImage, context: CIContext,
                       sourceSize: PixelSize, to size: PixelSize) throws -> any MTLTexture {
        let destination = try makeDestination(size)
        // Rows are handled top-down from here on: normalising the origin and then
        // flipping means the band a destination row needs is a plain row range.
        // A RAW development can arrive with a non-zero origin.
        let extent = image.extent
        let flipped = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                              tx: 0, ty: CGFloat(sourceSize.height)))
        let tables = Self.tables(source: sourceSize, destination: size)
        let bands = Self.bands(tables: tables.y, sourceHeight: sourceSize.height,
                              rowBudget: max(64, Self.bandBudgetBytes / max(1, sourceSize.width * 16)))
        for band in bands {
            try Task.checkCancellation()
            let height = band.sourceRows.upperBound - band.sourceRows.lowerBound
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: sourceSize.width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let bandTexture = device.makeTexture(descriptor: descriptor) else {
                throw RenderError.allocationFailed
            }
            guard let buffer = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
            let crop = CGRect(x: 0, y: band.sourceRows.lowerBound,
                              width: sourceSize.width, height: height)
            let bandImage = flipped.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: 0, y: -crop.minY))
            let render = CIRenderDestination(mtlTexture: bandTexture, commandBuffer: buffer)
            render.colorSpace = RenderEngine.workingColorSpace
            render.alphaMode = .unpremultiplied
            _ = try context.startTask(toRender: bandImage, to: render)
            // The tile holds full-resolution rows, so the destination rows are
            // written with an offset while the source rows are relative to it.
            let rows = band.destinationRows
            try encode(source: bandTexture, destination: destination,
                       tables: Tables(x: tables.x, y: tables.y, destinationRows: rows),
                       sourceOrigin: (0, -band.sourceRows.lowerBound),
                       destinationOriginY: rows.lowerBound, buffer: buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status == .completed else {
                throw RenderError.gpu(buffer.error?.localizedDescription ?? "analysis scaling failed")
            }
        }
        return destination
    }

    // MARK: - Kernel encoding

    private struct Tables {
        let x: AxisWeights
        let y: AxisWeights
        /// Destination rows to write; the kernel adds this to its row index.
        let destinationRows: Range<Int>
    }

    private func makeDestination(_ size: PixelSize) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: size.width, height: size.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.allocationFailed
        }
        return texture
    }

    private func encode(source: any MTLTexture, destination: any MTLTexture, tables: Tables,
                        sourceOrigin: (x: Int, y: Int), destinationOriginY: Int,
                        buffer: any MTLCommandBuffer) throws {
        guard let encoder = buffer.makeComputeCommandEncoder() else { throw RenderError.allocationFailed }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        let firstX = try bufferFor(tables.x.first)
        let countX = try bufferFor(tables.x.count)
        let weightsX = try bufferFor(tables.x.weights)
        let firstY = try bufferFor(tables.y.first)
        let countY = try bufferFor(tables.y.count)
        let weightsY = try bufferFor(tables.y.weights)
        encoder.setBuffer(firstX, offset: 0, index: 0)
        encoder.setBuffer(countX, offset: 0, index: 1)
        encoder.setBuffer(weightsX, offset: 0, index: 2)
        encoder.setBuffer(firstY, offset: 0, index: 3)
        encoder.setBuffer(countY, offset: 0, index: 4)
        encoder.setBuffer(weightsY, offset: 0, index: 5)
        var strideX = Int32(tables.x.taps)
        var strideY = Int32(tables.y.taps)
        var origin = SIMD2<Int32>(Int32(sourceOrigin.x), Int32(sourceOrigin.y))
        var rowOffset = Int32(destinationOriginY)
        encoder.setBytes(&strideX, length: MemoryLayout<Int32>.stride, index: 6)
        encoder.setBytes(&strideY, length: MemoryLayout<Int32>.stride, index: 7)
        encoder.setBytes(&origin, length: MemoryLayout<SIMD2<Int32>>.stride, index: 8)
        encoder.setBytes(&rowOffset, length: MemoryLayout<Int32>.stride, index: 9)
        // The kernel computes one destination pixel per thread but writes at a
        // fixed row offset, so the grid height is only this band's rows.
        let rows = tables.destinationRows.count
        encoder.dispatchThreads(MTLSize(width: destination.width, height: rows, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    /// Tap tables are bound per dispatch; Metal retains them until the command
    /// buffer completes, so no manual lifetime is needed here.
    private func bufferFor<T>(_ values: [T]) throws -> any MTLBuffer {
        let length = max(MemoryLayout<T>.stride, values.count * MemoryLayout<T>.stride)
        let result: (any MTLBuffer)?
        if values.isEmpty {
            result = device.makeBuffer(length: length, options: .storageModeShared)
        } else {
            result = values.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: length,
                                  options: .storageModeShared)
            }
        }
        guard let result else { throw RenderError.allocationFailed }
        return result
    }

    // MARK: - Weight tables

    struct TablesPair {
        let x: AxisWeights
        let y: AxisWeights
    }

    static func tables(source: PixelSize, destination: PixelSize) -> TablesPair {
        TablesPair(x: axisWeights(source: source.width, target: destination.width),
                   y: axisWeights(source: source.height, target: destination.height))
    }

    /// The engine's footprint for one output position on one axis.
    ///
    /// `footprint()` in `modules/image/src/resample.cpp`: shrinking integrates a
    /// uniform area, with the two edge pixels carrying only the fraction they
    /// cover; enlarging interpolates linearly about pixel centres.
    static func footprint(position: Int, input: Int, output: Int) -> (first: Int, weights: [Float]) {
        guard input > 0, output > 0 else { return (0, [1]) }
        let scale = Double(input) / Double(output)
        if input > output {
            let left = Double(position) * scale
            let right = min(Double(input), Double(position + 1) * scale)
            let first = Int(left.rounded(.down))
            let last = min(input - 1, Int(right.rounded(.up)) - 1)
            let interior = Float(1 / scale)
            let firstWeight = Float((min(right, Double(first) + 1) - left) / scale)
            let lastWeight = Float((right - max(left, Double(last))) / scale)
            var weights = [Float](repeating: interior, count: last - first + 1)
            weights[0] = firstWeight
            weights[weights.count - 1] = lastWeight
            return (first, weights)
        }
        let coordinate = min(max((Double(position) + 0.5) * scale - 0.5, 0), Double(input - 1))
        let first = Int(coordinate.rounded(.down))
        let last = min(first + 1, input - 1)
        if first == last { return (first, [1]) }
        let fraction = Float(coordinate - Double(first))
        return (first, [1 - fraction, fraction])
    }

    /// Composes the engine's staged halvings and final footprint into one tap
    /// table per output index.
    ///
    /// `resample_to` halves while a dimension is more than twice its target and
    /// then runs one equal-area stage; every stage is an equal-area box, so their
    /// composition is a single (slightly trapezoidal) kernel from the source to
    /// the destination. Composing it here keeps the GPU pass to one read of the
    /// source per destination pixel with the same weights the engine would use.
    static func axisWeights(source: Int, target: Int) -> AxisWeights {
        guard source > 0, target > 0 else { return identityAxis(size: 1) }
        // No reduction (or a stride-aligned analysis size that already matches):
        // each destination pixel is one source pixel.
        if source == target { return identityAxis(size: target) }
        var stages: [(input: Int, output: Int)] = []
        var current = source
        while current > 1 && current > target * 2 {
            let next = current / 2 + current % 2
            stages.append((current, next))
            current = next
        }
        if current != target { stages.append((current, target)) }

        // `kernels[i]` holds (index, weight) pairs in the input space of the stage
        // about to be composed, starting from the destination's own index.
        var kernels: [[(Int, Float)]] = (0..<target).map { [(Int($0), Float(1))] }
        for stage in stages.reversed() {
            kernels = kernels.map { kernel in
                var merged: [Int: Float] = [:]
                for (index, weight) in kernel {
                    let (first, weights) = footprint(position: index, input: stage.input,
                                                     output: stage.output)
                    for (offset, tapWeight) in weights.enumerated() {
                        merged[first + offset, default: 0] += tapWeight * weight
                    }
                }
                return merged.keys.sorted().map { ($0, merged[$0] ?? 0) }
            }
        }
        let taps = max(1, kernels.map(\.count).max() ?? 1)
        var first = [Int32](repeating: 0, count: target)
        var count = [Int32](repeating: 0, count: target)
        var weights = [Float](repeating: 0, count: target * taps)
        for (index, kernel) in kernels.enumerated() {
            first[index] = Int32(kernel.first?.0 ?? 0)
            count[index] = Int32(kernel.count)
            for (tap, entry) in kernel.enumerated() { weights[index * taps + tap] = entry.1 }
        }
        return AxisWeights(first: first, count: count, weights: weights, taps: taps)
    }

    static func identityAxis(size: Int) -> AxisWeights {
        AxisWeights(first: (0..<size).map { Int32($0) },
                    count: [Int32](repeating: 1, count: size),
                    weights: [Float](repeating: 1, count: size), taps: 1)
    }

    /// Splits the destination rows into bands whose source row spans fit a budget.
    struct Band {
        let destinationRows: Range<Int>
        let sourceRows: Range<Int>
    }

    static func bands(tables: AxisWeights, sourceHeight: Int, rowBudget: Int) -> [Band] {
        guard !tables.count.isEmpty else { return [] }
        var result: [Band] = []
        var start = 0
        while start < tables.count.count {
            let bandFirst = Int(tables.first[start])
            var end = start
            while end + 1 < tables.count.count {
                let last = Int(tables.first[end + 1]) + Int(tables.count[end + 1])
                if last - bandFirst > rowBudget { break }
                end += 1
            }
            let sourceEnd = min(sourceHeight, Int(tables.first[end]) + Int(tables.count[end]))
            result.append(Band(destinationRows: start..<(end + 1),
                               sourceRows: bandFirst..<max(bandFirst + 1, sourceEnd)))
            start = end + 1
        }
        return result
    }
}
