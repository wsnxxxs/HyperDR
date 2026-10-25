import Foundation
import CoreImage
import CoreML
import ImageIO
import Testing
@testable import HyperDRRender

struct ModelGainExifTests {
    private var complete: ModelGainCapture {
        ModelGainCapture(features: [8.643856189774724, -8.965784284662087, 2.8, 0, 35, 35])
    }

    @Test func captureRulesAndTransforms() {
        var exif: [String: Any] = [
            kCGImagePropertyExifISOSpeedRatings as String: [400],
            kCGImagePropertyExifExposureTime as String: 1.0 / 500,
            kCGImagePropertyExifFNumber as String: 2.8,
            kCGImagePropertyExifExposureBiasValue as String: 0,
            kCGImagePropertyExifFocalLength as String: 35,
            kCGImagePropertyExifFocalLenIn35mmFilm as String: 35
        ]
        func capture() -> ModelGainCapture { ModelGainCapture(properties: [kCGImagePropertyExifDictionary as String: exif]) }
        #expect(capture().isUsable)
        #expect(abs(capture().features[0]! - complete.features[0]!) < 1e-12)
        #expect(abs(capture().features[1]! - complete.features[1]!) < 1e-12)
        // Zero EV is recorded; zero focal length means unknown, not a measured zero.
        exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = 0
        #expect(!capture().isUsable)
        exif.removeValue(forKey: kCGImagePropertyExifExposureBiasValue as String)
        #expect(!capture().isUsable)
        #expect(!ModelGainCapture.empty.isUsable)
    }

    @Test(.enabled(if: ModelGainExifLevel.bundled() != nil, "private EXIF estimator is absent"))
    func fittedEstimatorReference() throws {
        let model = try #require(ModelGainExifLevel.bundled())
        // Frozen fitted sklearn/C++ reference values; no tree weights in tests.
        #expect(abs(model.predict(.empty) - 0.73748320701771175) < 1e-9)
        #expect(abs(model.predict(complete) - 0.79861616215399844) < 1e-9)
        let highISO = ModelGainCapture(features: [13.643856189774724, -5.906890595608519, 1.8, -0.67, 16, 24])
        #expect(abs(model.predict(highISO) - 0.52667847741907825) < 1e-9)
        let restored = model.restoringLevel(of: .init(size: .init(width: 2, height: 1), log2Stops: [10, 12]), capture: complete)
        #expect(abs(Double(restored.log2Stops[0]) - (model.predict(complete) - 1)) < 1e-6)
        #expect(abs(Double(restored.log2Stops[1]) - (model.predict(complete) + 1)) < 1e-6)
    }

    @Test(.needsModel) func automaticSelectionAndMissingResources() throws {
        let provider = try CoreMLModelGainProvider()
        #expect(provider.modelID(for: .empty).hasPrefix(ModelGain.modelName + "/"))
        let exifIncluded = ModelGain.bundledModel(named: ModelGain.exifModelName) != nil && ModelGainExifLevel.bundled() != nil
        #expect(provider.modelID(for: complete).hasPrefix((exifIncluded ? ModelGain.exifModelName : ModelGain.modelName) + "/"))
        // A bundle with model 1 alone is a supported private build, and a tree
        // without its matching spatial network must never select model 2.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let resources = directory.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try #require(ModelGain.bundledModel())
        let url: URL
        switch asset { case .package(let value), .compiled(let value): url = value }
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent(url.lastPathComponent), withDestinationURL: url)
        let bundle = try #require(Bundle(url: directory))
        #expect(ModelGainExifLevel.bundled(in: bundle) == nil)
        let fallback = try CoreMLModelGainProvider(bundle: bundle)
        #expect(fallback.modelID(for: complete) == fallback.modelID(for: .empty))
        #expect(fallback.modelID(for: complete).hasPrefix(ModelGain.modelName + "/"))
        if let exif = ModelGain.bundledModel(named: ModelGain.exifModelName) {
            let exifURL: URL
            switch exif { case .package(let value), .compiled(let value): exifURL = value }
            try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent(exifURL.lastPathComponent), withDestinationURL: exifURL)
            let missingTree = try CoreMLModelGainProvider(bundle: bundle)
            #expect(missingTree.modelID(for: complete) == missingTree.modelID(for: .empty))
        }
    }

    @Test(.needsModel, .enabled(if: ModelGain.bundledModel(named: ModelGain.exifModelName) != nil && ModelGainExifLevel.bundled() != nil,
                               "private EXIF model is absent"))
    func providerRestoresLevelAndSeparatesCachedModels() async throws {
        let engine = try RenderEngine()
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 192))
        var source = try await engine.source(image: image, domain: .sdr)
        source.modelCapture = complete
        let provider = try CoreMLModelGainProvider()
        let exif = try await engine.predictModelGain(source, provider: provider)
        #expect(exif.modelID.hasPrefix(ModelGain.exifModelName + "/"))
        let stops = RenderEngine.readTexture(exif.gain)
        let mean = stops.reduce(0.0) { $0 + Double($1) } / Double(stops.count)
        let estimator = try #require(ModelGainExifLevel.bundled())
        #expect(abs(mean - estimator.predict(complete)) < 1e-6)
        source.modelCapture = .empty
        let fallback = try await engine.predictModelGain(source, provider: provider)
        #expect(fallback.modelID.hasPrefix(ModelGain.modelName + "/"))
        #expect(fallback.gain !== exif.gain)
        source.modelCapture = complete
        let repeated = try await engine.predictModelGain(source, provider: provider)
        #expect(repeated.gain === exif.gain)
    }

}
