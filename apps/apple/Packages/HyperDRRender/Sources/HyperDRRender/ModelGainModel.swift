import Foundation
import CoreML

/// The Core ML AI gain model.
///
/// One instance owns one loaded model and may be shared, but predictions through
/// it are serialized: Core ML requires that one `MLModel` is used by one thread or
/// queue at a time, so a preview and an export asking at once would otherwise be
/// a contract violation. Everything else here is immutable, so sharing is safe as
/// long as every call goes through `gain(for:)`. Callers should keep one instance
/// for the life of the process; loading is the expensive part.
///
/// Compute units default to `.all`, so the model runs on the neural engine and
/// the GPU where the system chooses. The numbers the tests compare are produced
/// with both `.all` and `.cpuOnly`: the first is what ships, the second isolates
/// the conversion from a compute-unit specific kernel.
///
/// The converted model keeps a flexible spatial extent (multiples of 16) because
/// the analysis grid depends on the photograph's aspect and the network's group
/// normalisation makes the prediction depend on that grid.
public final class ModelGainModel: @unchecked Sendable {
    public let version: String
    public let modelIdentifier: String
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    /// Serializes predictions for the duration of one `predict` call. A response
    /// is already queued behind any other in flight, so two callers never touch
    /// the same `MLModel` concurrently.
    private let predictionQueue = DispatchQueue(label: "hyperdr.modelgain.mlmodel")

    /// Model identity without a grid: what a cached gain grid depends on besides
    /// its own input.
    public var identityKey: String {
        "modelGain/coreml/\(modelIdentifier)/\(version)/\(ModelGain.preprocessingRevision)"
    }

    public func cacheKey(for features: ModelGainFeatures) -> String {
        "\(identityKey)/\(features.size.width)x\(features.size.height)"
    }

    public func cacheKey(tensorSize: PixelSize) -> String {
        "\(identityKey)/\(tensorSize.width)x\(tensorSize.height)"
    }

    public init(computeUnits: MLComputeUnits = .all,
                bundle: Bundle? = nil) throws {
        guard !MLModel.availableComputeDevices.isEmpty else {
            throw ModelGainError.deviceUnavailable("Core ML has no available compute device")
        }
        let bundle = bundle ?? Bundle.module
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiled: URL
        if let url = bundle.url(forResource: ModelGain.modelName, withExtension: "mlmodelc") {
            compiled = url
        } else if let package = bundle.url(forResource: ModelGain.modelName, withExtension: "mlpackage") {
            compiled = try Self.compileOnce(package)
        } else {
            throw ModelGainError.modelUnavailable("\(ModelGain.modelName).mlmodelc is not in the bundle")
        }
        do {
            model = try MLModel(contentsOf: compiled, configuration: configuration)
        } catch {
            throw ModelGainError.modelUnavailable("cannot load \(compiled.lastPathComponent): \(error)")
        }
        let description = model.modelDescription
        // The converted graph has exactly one tensor in and one out. Naming them
        // by position rather than by a literal keeps the loader working if the
        // exported names ever change, and refusing anything else keeps a future
        // multi-input model from being fed the wrong half.
        guard description.inputDescriptionsByName.count == 1,
              description.outputDescriptionsByName.count == 1,
              let input = description.inputDescriptionsByName.keys.first,
              let output = description.outputDescriptionsByName.keys.first else {
            throw ModelGainError.modelUnavailable("expected one input and one output tensor")
        }
        inputName = input
        outputName = output
        let metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        modelIdentifier = metadata["hyperdr.modelId"] ?? ModelGain.modelName
        version = metadata["hyperdr.modelVersion"] ?? ModelGain.modelVersion
        // Catch a stale bundled asset now instead of on the first prediction.
        guard description.inputDescriptionsByName[inputName]?.multiArrayConstraint != nil else {
            throw ModelGainError.modelUnavailable("model input \(inputName) is not a multi-array")
        }
    }

    /// Compiles the bundled package once per process and shares the result.
    ///
    /// A `.mlmodelc` in the bundle skips this entirely. When the bundle carries
    /// the `.mlpackage` verbatim (the Swift package case), Core ML has to compile
    /// it at runtime; doing it once keeps a second `ModelGainModel` — the tests
    /// load one per compute unit — from paying for it twice.
    private static func compileOnce(_ package: URL) throws -> URL {
        let key = package.standardizedFileURL.path
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = compiledModels[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let compiled: URL
        do {
            compiled = try MLModel.compileModel(at: package)
        } catch {
            throw ModelGainError.modelUnavailable("cannot compile \(package.lastPathComponent): \(error)")
        }
        compiledModels[key] = compiled
        return compiled
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var compiledModels: [String: URL] = [:]

    /// Runs one prediction on an analysis grid.
    ///
    /// The tensor is validated against the model's own constraints first: a grid
    /// that is not a multiple of the stride, or channels that do not match, is a
    /// caller bug and should not reach the neural engine as an opaque failure.
    public func gain(for features: ModelGainFeatures) throws -> ModelGainGrid {
        try predictionQueue.sync { try predict(features) }
    }

    private func predict(_ features: ModelGainFeatures) throws -> ModelGainGrid {
        let size = features.size
        guard size.width % ModelGain.stride == 0, size.height % ModelGain.stride == 0 else {
            throw ModelGainError.invalidTensorSize(size)
        }
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: [1, NSNumber(value: ModelGainFeatures.channelCount),
                                             NSNumber(value: size.height), NSNumber(value: size.width)],
                                     dataType: .float32)
        } catch {
            throw ModelGainError.predictionFailed("cannot allocate the feature tensor: \(error)")
        }
        array.withUnsafeMutableBytes { destination, _ in
            let target = destination.bindMemory(to: Float.self)
            features.planes.withUnsafeBufferPointer { source in
                for index in 0..<target.count { target[index] = source[index] }
            }
        }
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: array)])
        } catch {
            throw ModelGainError.predictionFailed("cannot build the model input: \(error)")
        }
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw ModelGainError.predictionFailed(String(describing: error))
        }
        guard let value = output.featureValue(for: outputName)?.multiArrayValue else {
            throw ModelGainError.predictionFailed("the model returned no \(outputName)")
        }
        let expected = ModelGain.gridSize(for: size)
        guard value.shape.count == 4,
              value.shape[2].intValue == expected.height,
              value.shape[3].intValue == expected.width,
              value.count == expected.width * expected.height else {
            let actual = value.shape.count == 4
                ? PixelSize(width: value.shape[3].intValue, height: value.shape[2].intValue)
                : PixelSize(width: value.count, height: 1)
            throw ModelGainError.unexpectedGrid(expected: expected, actual: actual)
        }
        var stops = [Float](repeating: 0, count: expected.width * expected.height)
        switch value.dataType {
        case .float16:
            value.withUnsafeBytes { source in
                let values = source.bindMemory(to: Float16.self)
                for index in 0..<stops.count { stops[index] = Float(values[index]) }
            }
        case .double:
            value.withUnsafeBytes { source in
                let values = source.bindMemory(to: Double.self)
                for index in 0..<stops.count { stops[index] = Float(values[index]) }
            }
        case .float32:
            value.withUnsafeBytes { source in
                let values = source.bindMemory(to: Float.self)
                for index in 0..<stops.count { stops[index] = values[index] }
            }
        default:
            throw ModelGainError.predictionFailed("unexpected gain data type \(value.dataType.rawValue)")
        }
        return ModelGainGrid(size: expected, log2Stops: stops)
    }

    /// Convenience for a base that is already linear Display-P3 RGB.
    public func gain(linearP3RGB rgb: [Float], size: PixelSize) throws -> ModelGainGrid {
        try gain(for: ModelGainFeatures.make(linearP3RGB: rgb, size: size))
    }
}
