import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import HyperDREngine
import HyperDRRecipe
import HyperDRRender
import Metal
import Synchronization
import Testing
@testable import HyperDRKit

private struct StripeFake: ExportStripeRendering {
    var metadata: ExportGainMetadata? = nil
    var before: @Sendable () async throws -> Void = {}
    var afterStripe: @Sendable () throws -> Void = {}
    func renderExportStripes(_ source: RenderSource, recipe: Recipe, lut: ColorLUT?,
                             modelGain: ModelGainPrediction?, request: ExportRenderRequest, rows: Int,
                             prepare: @Sendable (ExportRenderReport) throws -> Void,
                             consume: @Sendable (ExportStripe) throws -> Void) async throws -> ExportRenderReport {
        try await before()
        try Task.checkCancellation()
        let channels = request.includesGain ? metadata?.channelCount ?? 1 : 0
        let size = request.canvasSize
        let report = ExportRenderReport(canvasSize: size,
            gain: channels == 0 ? nil : metadata ?? .init(channelCount: channels, alternateHeadroom: 2),
            provenance: .split, resplitReasons: [], resolvedAutomatic: ["hdr.range": 2],
            presentationFrame: request.frame != nil, framePhoto: request.frame?.photo)
        try prepare(report)
        for y in stride(from: 0, to: size.height, by: rows) {
            let count = min(rows, size.height-y)
            var base = [Float](), gain = [Float]()
            for sy in y..<(y+count) { for x in 0..<size.width {
                let inside = request.frame.map { x >= $0.photo.x && x < $0.photo.x+$0.photo.width
                    && sy >= $0.photo.y && sy < $0.photo.y+$0.photo.height } ?? true
                let paper = request.frame?.paper ?? SIMD3<Float>(repeating: 0.8)
                base += inside ? [0.25 + Float(x)/Float(size.width)*0.5, 0.5, 0.25] : [paper.x, paper.y, paper.z]
                if channels > 0 { gain += [Float](repeating: inside ? 2 * Float(x)/Float(max(size.width-1,1)) : 0, count: channels) }
            } }
            try consume(.init(rect: .init(x: 0, y: y, width: size.width, height: count), baseRGB: base, gain: gain))
            try afterStripe()
        }
        return report
    }
}

private struct RecipeExportEnvironment {
    let root: URL
    let configuration: KitConfiguration
    let engine: Engine
    let render: RenderEngine
    let sessions: SessionStore
    let target: ExportTarget
    let photo: TinyPhoto
    let session: PhotoSession
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-export-\(UUID())")
        configuration = KitConfiguration(supportDirectory: root.appendingPathComponent("support"),
                                         cacheDirectory: root.appendingPathComponent("cache"))
        engine = try await Engine(configuration: .init(cacheDirectory: configuration.cacheDirectory))
        render = try RenderEngine()
        sessions = SessionStore(configuration: configuration, formats: try InputFormats(schema: Engine.schema()))
        target = ExportTarget(configuration: configuration, sessions: sessions)
        photo = try TinyPhoto()
        session = try await sessions.open(photo.url)
    }
    func service(_ fake: StripeFake = StripeFake(), budget: Int = 1_000_000_000,
                 prediction: RecipeExportService.Prediction? = nil) -> RecipeExportService {
        .init(engine: engine, renderEngine: render, renderer: fake, sessions: sessions,
              target: target, budget: FixedExportMemoryBudget(bytes: budget), prediction: prediction)
    }
    func snapshot(recipe: Recipe = Recipe(), frame: FrameSnapshot? = nil, modelID: String? = nil) throws -> RecipeExportSnapshot {
        .init(recipe: recipe, source: try .init(session: session), modelID: modelID, frame: frame)
    }
    func request(_ encoding: ExportEncoding) -> ExportPlanRequest {
        .init(choice: .custom(.init(encoding: encoding, gamut: .p3, quality: 95)),
              source: .init(domain: .sdr, pixelSize: .init(width: 96, height: 64)),
              edit: .init(peakStops: 2))
    }
    func remove() { photo.remove(); try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct RecipeExportTests {
    @Test func eightEncodingsArePackagedAndReadByBothReaders() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        for encoding in ExportEncoding.allCases {
            let result = try await env.service().export(session: env.session.id, snapshot: env.snapshot(), request: env.request(encoding))
            #expect(FileManager.default.fileExists(atPath: result.file.path))
            #expect(result.record.recipeSnapshot?.recipe == Recipe())
            #expect(result.record.resolvedSnapshot == result.resolved)
            let evidence = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
            let package = try JSONDecoder().decode(PackageReport.self, from: #require(evidence.packageJSON))
            #expect(package.schema == "hyperdr.package/v1")
            #expect(package.verified)
            #expect(evidence.system.width == 96 && evidence.system.height == 64)
            #expect(evidence.system.auxiliaryGain == encoding.writesGainMap)
            #expect(await env.sessions.exportThumbnail(env.session.id, export: result.record.id) != nil)
        }
        #expect(await env.sessions.exports(for: env.session.id).count == 8)
    }

    @Test func sdrHEICContainsNoAuxiliaryAndRoundTripsTheSnapshot() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var recipe = Recipe(); recipe.setValue(.bool(false), for: "hdr.enabled")
        let snapshot = try env.snapshot(recipe: recipe)
        try await env.sessions.saveRecipe(snapshot, for: env.session.id)
        #expect(try await env.sessions.recipe(for: env.session.id) == snapshot)
        let result = try await env.service().export(session: env.session.id, snapshot: snapshot, request: env.request(.adaptive))
        let evidence = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
        #expect(evidence.packageJSON == nil)
        #expect(evidence.firstReaderJSON != nil)
        #expect(!evidence.system.auxiliaryGain && !evidence.system.hdrReadable)
        #expect(result.resolved.bitDepth == 8)
    }

    @Test func frameIsFrozenInHistoryAndReceivesE5Readback() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let png = NSMutableData()
        let context = try #require(CGContext(data: nil, width: 112, height: 16, bitsPerComponent: 8, bytesPerRow: 112*4,
            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.2, alpha: 0.8)); context.fill(CGRect(x: 20, y: 2, width: 72, height: 12))
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        let frame = FrameSnapshot(canvasSize: .init(width: 112, height: 88),
                                  photo: .init(x: 8, y: 8, width: 96, height: 64), paper: .init(repeating: 0.8),
                                  caption: .init(png: png as Data, rect: .init(x: 0, y: 72, width: 112, height: 16)))
        let snapshot = try env.snapshot(frame: frame)
        let restored = try JSONDecoder().decode(RecipeExportSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.frame?.captionPNG == nil)
        try await env.sessions.saveRecipe(snapshot, for: env.session.id)
        #expect(try await env.sessions.resolveFrame(restored.frame, for: env.session.id) == frame)
        let result = try await env.service().export(session: env.session.id, snapshot: snapshot, request: env.request(.isoGainMapJPEG))
        let evidence = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
        let package = try JSONDecoder().decode(PackageReport.self, from: #require(evidence.packageJSON))
        #expect(package.verified && package.width == 112 && package.height == 88)
        #expect(result.record.recipeSnapshot?.frame == snapshot.frame)
    }

    @Test func rgbGainAndUnequalOffsetsArePassedToTheISOWriter() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let metadata = ExportGainMetadata(channelCount: 3, baseOffset: .init(0.01, 0.02, 0.03),
                                          alternateOffset: .init(0.02, 0.01, 0.04), alternateHeadroom: 2)
        let result = try await env.service(StripeFake(metadata: metadata)).export(
            session: env.session.id, snapshot: env.snapshot(), request: env.request(.isoGainMapJPEG))
        #expect(result.resolved.gain?.channels == 3)
        #expect(result.resolved.gain?.baseOffset == metadata.baseOffset)
        #expect(result.resolved.gain?.alternateOffset == metadata.alternateOffset)
        let evidence = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
        let package = try JSONDecoder().decode(PackageReport.self, from: #require(evidence.packageJSON))
        #expect(package.gain?.channels == 3)
        #expect(evidence.system.verifiedHeadroomStops == [2, 1])
    }

    @Test func sdrAndHDRSamplesMatchTheRenderedPlanesAtDeclaredHeadrooms() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let context = CIContext(options: [.cacheIntermediates: false])
        let color = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        for encoding in [ExportEncoding.sdrTIFF, .isoGainMapJPEG, .adaptive] {
            let result = try await env.service().export(session: env.session.id, snapshot: env.snapshot(), request: env.request(encoding))
            let base = try #require(CIImage(contentsOf: result.file, options: [.expandToHDR: false]))
            let gain = encoding.writesGainMap ? CIImage(contentsOf: result.file, options: [.auxiliaryHDRGainMap: true]) : nil
            for stops: Float in encoding.writesGainMap ? [1, 2] : [0] {
                let image = gain.map { base.applyingGainMap($0, headroom: pow(2, stops)) } ?? base
                var values = [Float](repeating: 0, count: 4)
                values.withUnsafeMutableBytes { bytes in
                    context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                                   bounds: CGRect(x: 48, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: color)
                }
                let multiplier = pow(2, Float(48) / 95 * stops)
                let tolerance: Float = encoding == .sdrTIFF ? 0.001 : 0.07
                #expect(abs(values[0] - 0.5 * multiplier) < tolerance)
                #expect(abs(values[1] - 0.5 * multiplier) < tolerance)
                #expect(abs(values[2] - 0.25 * multiplier) < tolerance)
            }
        }
    }

    @Test func changedSourceAndInsufficientMemoryPublishNothing() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let snapshot = try env.snapshot()
        await #expect(throws: RecipeExportError.self) {
            _ = try await env.service(budget: 1).export(session: env.session.id, snapshot: snapshot, request: env.request(.sdrJPEG))
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: env.photo.url.path)
        await #expect(throws: RecipeExportError.sourceChanged) {
            _ = try await env.service().export(session: env.session.id, snapshot: snapshot, request: env.request(.sdrJPEG))
        }
        #expect(await env.sessions.exports(for: env.session.id).isEmpty)
    }

    @Test func cancellationDiscardsPartialStripes() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let service = env.service(StripeFake(afterStripe: { throw CancellationError() }))
        await #expect(throws: CancellationError.self) {
            _ = try await service.export(session: env.session.id, snapshot: env.snapshot(), request: env.request(.sdrJPEG))
        }
        #expect(await env.sessions.exports(for: env.session.id).isEmpty)
    }

    @Test func aiIsAwaitedAndFailureDoesNotFallBack() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var recipe = Recipe(); recipe.setHDRSource(.ai)
        let ready = Mutex(false)
        let fake = StripeFake(before: { #expect(ready.withLock { $0 }) })
        let service = env.service(fake, prediction: { source, model in
            try await Task.sleep(for: .milliseconds(10))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
            let device = try #require(MTLCreateSystemDefaultDevice())
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            ready.withLock { $0 = true }
            return .init(sourceID: source.id, modelID: model, gain: texture)
        })
        _ = try await service.export(session: env.session.id, snapshot: env.snapshot(recipe: recipe, modelID: "test-v1"), request: env.request(.sdrJPEG))
        let failing = env.service(prediction: { _, _ in throw RecipeExportError.missingModel })
        await #expect(throws: RecipeExportError.missingModel) {
            _ = try await failing.export(session: env.session.id, snapshot: env.snapshot(recipe: recipe, modelID: "test-v1"), request: env.request(.sdrJPEG))
        }
        #expect(await env.sessions.exports(for: env.session.id).count == 1)
    }

    @Test func cancellationAtEncodingForwardsToTheEngineAndReleasesAdmission() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let service = env.service()
        let holder = Mutex<Task<RecipeExportResult, Error>?>(nil)
        let job = Task {
            try await service.export(session: env.session.id, snapshot: env.snapshot(), request: env.request(.isoGainMapJPEG),
                progress: { event in if event.stage == .encoding { holder.withLock { $0?.cancel() } } })
        }
        holder.withLock { $0 = job }
        do { _ = try await job.value; Issue.record("Cancelled encoding returned a successful export") }
        catch is CancellationError {}
        catch let error as HyperDRError { #expect(error.code == "cancelled") }
        #expect(await env.sessions.exports(for: env.session.id).isEmpty)
        _ = try await service.export(session: env.session.id, snapshot: env.snapshot(), request: env.request(.sdrJPEG))
        #expect(await env.sessions.exports(for: env.session.id).count == 1)
    }

    @Test func retainedLUTSurvivesRemovalFromTheLibrary() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let cube = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
        let url = env.root.appendingPathComponent("identity.cube")
        try Data(cube.utf8).write(to: url)
        let library = LUTLibrary(configuration: env.configuration, sessions: env.sessions)
        let entry = try await library.importLUT(url, into: env.session.id)
        let lut = try ColorLUT(cube: cube)
        var recipe = Recipe(); recipe.look = .init(contentHash: lut.contentHash, name: "Identity")
        let snapshot = try env.snapshot(recipe: recipe)
        try await env.sessions.saveRecipe(snapshot, for: env.session.id)
        try await library.remove(entry.id)
        let renderer = StripeFake(before: {
            let retained = try await env.sessions.recipeLUT(lut.contentHash, for: env.session.id)
            #expect(retained.contentHash == lut.contentHash)
        })
        _ = try await env.service(renderer).export(session: env.session.id, snapshot: snapshot, request: env.request(.sdrTIFF))
        #expect(await env.sessions.exports(for: env.session.id).first?.recipeSnapshot?.lutContentHash == lut.contentHash)
    }

    @Test func aFailedDeliveryRetainsTheVerifiedVersion() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let destination = env.root.appendingPathComponent("chosen.jpg")
        // Remove the selected directory after admission, during render.
        let folder = env.root.appendingPathComponent("chosen-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let selected = folder.appendingPathComponent(destination.lastPathComponent)
        let fake = StripeFake(before: { try FileManager.default.removeItem(at: folder) })
        let result = try await env.service(fake).export(session: env.session.id, snapshot: env.snapshot(), request: env.request(.sdrJPEG), destination: selected)
        #expect(result.deliveryError != nil && result.saved == nil)
        #expect(FileManager.default.fileExists(atPath: result.file.path))
        #expect(await env.sessions.exports(for: env.session.id).count == 1)
    }

    @Test func aSelectedDestinationReceivesTheFileAndSavedMark() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let selected = env.root.appendingPathComponent("saved.jpg")
        let result = try await env.service().export(session: env.session.id, snapshot: env.snapshot(),
            request: env.request(.sdrJPEG), destination: selected)
        #expect(result.deliveryError == nil)
        #expect(result.saved?.url.resolvingSymlinksInPath() == selected.resolvingSymlinksInPath())
        #expect(result.record.saved?.fileName == "saved.jpg")
        #expect(try Data(contentsOf: selected) == Data(contentsOf: result.file))
        #expect(await env.sessions.exports(for: env.session.id).first?.saved?.fileName == "saved.jpg")
    }

    @Test func keyIgnoresLUTBookmarkAndDisplayName() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var a = Recipe(), b = Recipe()
        a.look = .init(contentHash: "sha256:abc", name: "A", bookmark: Data([1]))
        b.look = .init(contentHash: "sha256:abc", name: "B", bookmark: Data([2]))
        let plan = ExportPlanner.plan(env.request(.sdrJPEG), budget: FixedExportMemoryBudget(bytes: 1_000_000_000))
        let first = ResolvedExportSnapshot(snapshot: try env.snapshot(recipe: a), plan: plan)
        let second = ResolvedExportSnapshot(snapshot: try env.snapshot(recipe: b), plan: plan)
        #expect(try first.exportKey() == second.exportKey())
    }
}
