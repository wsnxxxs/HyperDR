import Foundation
import ImageIO

/// The six ordinary EXIF fields used by the frozen research estimator.
/// A partial capture falls back to the pixel-only model, as the original runtime did.
public struct ModelGainCapture: Sendable, Equatable {
    /// Training order: log2 ISO, log2 seconds, f-number, signed EV, mm, 35mm equivalent.
    let features: [Double?]
    public static let empty = Self(features: Array(repeating: nil, count: 6))
    public var isUsable: Bool { features.count == 6 && features.allSatisfy { $0?.isFinite == true } }

    init(properties: [String: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func number(_ key: CFString) -> Double? {
            let value = exif[key as String]
            let number = (value as? NSNumber) ?? (value as? [NSNumber])?.first
            guard let value = number?.doubleValue, value.isFinite else { return nil }
            return value
        }
        func positive(_ key: CFString) -> Double? { number(key).flatMap { $0 > 0 ? $0 : nil } }
        func nonzero(_ key: CFString) -> Double? { number(key).flatMap { $0 != 0 ? $0 : nil } }
        features = [
            positive(kCGImagePropertyExifISOSpeedRatings).map { log2(max($0, 1)) },
            positive(kCGImagePropertyExifExposureTime).map { log2(max($0, 1e-6)) },
            positive(kCGImagePropertyExifFNumber), number(kCGImagePropertyExifExposureBiasValue),
            nonzero(kCGImagePropertyExifFocalLength), nonzero(kCGImagePropertyExifFocalLenIn35mmFilm)
        ]
    }

    init(features: [Double?]) { self.features = features }
}

/// Private fitted data, never compiled into the public source or test fixtures.
struct ModelGainExifLevel: Decodable, Sendable {
    struct Tree: Decodable, Sendable {
        let feature: [Int]
        let threshold: [Double]
        let left: [Int]
        let right: [Int]
        let is_leaf: [Bool]
        let value: [Double]
    }
    let imputer_statistics: [Double]
    let baseline: Double
    let trees: [Tree]

    static func bundled(in bundle: Bundle? = nil) -> Self? {
        let bundle = bundle ?? .module
        guard let url = bundle.url(forResource: ModelGain.exifModelName + ".exif-level",
                                   withExtension: "json", subdirectory: ModelGain.resourceDirectory),
              let data = try? Data(contentsOf: url), let model = try? JSONDecoder().decode(Self.self, from: data),
              model.isValid else { return nil }
        return model
    }

    private var isValid: Bool {
        guard imputer_statistics.count == 6, imputer_statistics.allSatisfy(\.isFinite),
              baseline.isFinite, !trees.isEmpty else { return false }
        return trees.allSatisfy { tree in
            let count = tree.value.count
            guard count > 0, [tree.feature.count, tree.threshold.count, tree.left.count,
                              tree.right.count, tree.is_leaf.count].allSatisfy({ $0 == count }) else { return false }
            return (0..<count).allSatisfy { i in
                tree.value[i].isFinite && (tree.is_leaf[i] ||
                    ((0..<6).contains(tree.feature[i]) && tree.threshold[i].isFinite &&
                     (i+1..<count).contains(tree.left[i]) && (i+1..<count).contains(tree.right[i])))
            }
        }
    }

    func predict(_ capture: ModelGainCapture) -> Double {
        let values = zip(capture.features, imputer_statistics).map { value, median in
            value.flatMap { $0.isFinite ? $0 : nil } ?? median
        }
        return trees.reduce(baseline) { total, tree in
            var node = 0
            while !tree.is_leaf[node] {
                node = values[tree.feature[node]] <= tree.threshold[node] ? tree.left[node] : tree.right[node]
            }
            // The fitted leaf already includes the learning rate.
            return total + tree.value[node]
        }
    }

    func restoringLevel(of grid: ModelGainGrid, capture: ModelGainCapture) -> ModelGainGrid {
        let mean = grid.log2Stops.reduce(0.0) { $0 + Double($1) } / Double(grid.log2Stops.count)
        let level = predict(capture)
        return ModelGainGrid(size: grid.size, log2Stops: grid.log2Stops.map { Float(Double($0) - mean + level) })
    }
}
