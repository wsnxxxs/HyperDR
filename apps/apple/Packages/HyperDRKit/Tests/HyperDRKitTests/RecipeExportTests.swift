import Foundation
import Darwin
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

private final class ChangingExportMemoryBudget: ExportMemoryBudget {
    let bytes: Mutex<Int>
    init(_ initial: Int) { bytes = Mutex(initial) }
    func availableBytes() -> Int? { bytes.withLock { $0 } }
}

struct StripeFake: ExportStripeRendering, ExportRowRendering {
    var metadata: ExportGainMetadata? = nil
    var gainScale: Float = 2
    var before: @Sendable () async throws -> Void = {}
    var afterStripe: @Sendable () throws -> Void = {}
    var onRead: @Sendable (Int, Int) -> Void = { _, _ in }
    func report(_ request: ExportRenderRequest) -> ExportRenderReport {
        let channels = request.includesGain ? metadata?.channelCount ?? 1 : 0
        return .init(canvasSize: request.canvasSize,
            gain: channels == 0 ? nil : metadata ?? .init(channelCount: channels, alternateHeadroom: 2),
            sourceProvenance: .split, provenance: .split, resplitReasons: [],
            rangeBeforeCeiling: gainScale, rangeAfterCeiling: gainScale, resolvedAutomatic: ["hdr.range": 2],
            presentationFrame: request.frame != nil, framePhoto: request.frame?.photo)
    }
    func stripe(_ request: ExportRenderRequest, y: Int, count: Int) -> ExportStripe {
        let channels = request.includesGain ? metadata?.channelCount ?? 1 : 0
        let size = request.canvasSize
        var base = [Float](), gain = [Float]()
        for sy in y..<(y+count) { for x in 0..<size.width {
            let inside = request.frame.map { x >= $0.photo.x && x < $0.photo.x+$0.photo.width
                && sy >= $0.photo.y && sy < $0.photo.y+$0.photo.height } ?? true
            let paper = request.frame?.paper ?? SIMD3<Float>(repeating: 0.8)
            base += inside ? [0.25 + Float(x)/Float(size.width)*0.5, 0.5, 0.25] : [paper.x, paper.y, paper.z]
            if channels > 0 { gain += [Float](repeating: inside ? gainScale * Float(x)/Float(max(size.width-1,1)) : 0, count: channels) }
        } }
        return .init(rect: .init(x: 0, y: y, width: size.width, height: count), baseRGB: base, gain: gain)
    }
    func prepareRows(_ source: HyperDRRender.ExportSource, recipe: Recipe, lut: ColorLUT?,
                     modelGain: ModelGainPrediction?, request: ExportRenderRequest,
                     rows: Int) async throws -> any ExportRowSource {
        try await before()
        return FakeRows(fake: self, request: request, report: report(request))
    }
    func renderExportStripes(_ source: RenderSource, recipe: Recipe, lut: ColorLUT?,
                             modelGain: ModelGainPrediction?, request: ExportRenderRequest, rows: Int,
                             prepare: @Sendable (ExportRenderReport) throws -> Void,
                             consume: @Sendable (ExportStripe) throws -> Void) async throws -> ExportRenderReport {
        try await before()
        try Task.checkCancellation()
        let report = report(request)
        try prepare(report)
        for y in stride(from: 0, to: request.canvasSize.height, by: rows) {
            try consume(stripe(request, y: y, count: min(rows, request.canvasSize.height-y)))
            try afterStripe()
        }
        return report
    }
}

private struct FakeRows: ExportRowSource {
    let fake: StripeFake
    let request: ExportRenderRequest
    let report: ExportRenderReport
    func read(y: Int, count: Int) throws -> ExportStripe {
        fake.onRead(y, count)
        let stripe = fake.stripe(request, y: y, count: count)
        try fake.afterStripe()
        return stripe
    }
}

struct RecipeExportEnvironment {
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
        sessions = SessionStore(configuration: configuration, formats: InputFormats())
        target = ExportTarget(configuration: configuration, sessions: sessions)
        photo = try TinyPhoto()
        session = try await sessions.open(photo.url)
    }
    func service(_ fake: StripeFake = StripeFake(), budget: Int = 1_000_000_000,
                 prediction: RecipeExportService.Prediction? = nil) -> RecipeExportService {
        .init(engine: engine, renderEngine: render, renderer: fake, sessions: sessions,
              target: target, budget: FixedExportMemoryBudget(bytes: budget), prediction: prediction)
    }
    func realService(prediction: RecipeExportService.Prediction? = nil) -> RecipeExportService {
        .init(engine: engine, renderEngine: render, renderer: render, sessions: sessions,
              target: target, budget: FixedExportMemoryBudget(bytes: 1_000_000_000), prediction: prediction)
    }
    func snapshot(recipe: Recipe = Recipe(), frame: FrameSnapshot? = nil, modelID: String? = nil) throws -> RecipeExportSnapshot {
        .init(recipe: recipe, source: try .init(session: session), expectedModelIdentity: modelID, frame: frame)
    }
    func request(_ encoding: ExportEncoding) -> ExportPlanRequest {
        .init(choice: .custom(.init(encoding: encoding, gamut: .p3, quality: 95)),
              source: .init(domain: .sdr, pixelSize: .init(width: 96, height: 64)),
              edit: .init(peakStops: 2))
    }
    func remove() { photo.remove(); try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct RecipeExportTests {
    @Test func realRecipeRenderReachesAllEightWritersAndBothReaders() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let service = env.realService()
        var recipe = Recipe()
        recipe.setValue(.number(0.25), for: "tone.exposure")
        recipe.setValue(.number(2), for: "hdr.range")
        for encoding in ExportEncoding.allCases {
            let result = try await service.export(session: env.session.id, snapshot: env.snapshot(recipe: recipe),
                                                  request: env.request(encoding))
            let evidence = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
            if result.resolved.writer == .imageIO {
                #expect(evidence.packageJSON == nil && evidence.imageIO != nil && evidence.firstReaderJSON != nil)
            } else {
                let package = try JSONDecoder().decode(PackageReport.self, from: #require(evidence.packageJSON))
                #expect(package.verified)
            }
            #expect(result.size == ExportPixelSize(width: 96, height: 64))
            #expect(result.byteCount == result.record.byteCount)
            #expect(result.verified)
            #expect(result.elapsed > .zero)
            #expect((result.peakStops != nil) == !encoding.isSDR)
            #expect(result.resolved.snapshot.recipe == recipe)
            #expect(evidence.system.auxiliaryGain == encoding.writesGainMap)
            #expect(evidence.system.width == 96 && evidence.system.height == 64)
        }
        recipe.setValue(.bool(false), for: "hdr.enabled")
        let sdr = try await service.export(session: env.session.id, snapshot: env.snapshot(recipe: recipe), request: env.request(.adaptive))
        let ordinary = try JSONDecoder().decode(RecipeExportReport.self, from: sdr.record.reportJSON)
        #expect(ordinary.packageJSON == nil && ordinary.firstReaderJSON != nil)
        #expect(!ordinary.system.auxiliaryGain && !ordinary.system.hdrReadable)
        #expect(await env.sessions.exports(for: env.session.id).count == 9)
    }

    @Test func realFramedRenderSetsOnlyGainMapFrameRectangles() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let service = env.realService()
        let caption = NSMutableData()
        let captionContext = try #require(CGContext(data: nil, width: 112, height: 16, bitsPerComponent: 8, bytesPerRow: 112*4,
            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        captionContext.setFillColor(CGColor(gray: 0.1, alpha: 0.8))
        captionContext.fill(CGRect(x: 20, y: 2, width: 72, height: 12))
        let captionWriter = try #require(CGImageDestinationCreateWithData(caption, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(captionWriter, try #require(captionContext.makeImage()), nil)
        try #require(CGImageDestinationFinalize(captionWriter))
        let frame = FrameSnapshot(canvasSize: .init(width: 112, height: 88),
            photo: .init(x: 8, y: 8, width: 96, height: 64), paper: .init(repeating: 0.8),
            shadow: .init(opacity: 0.2, sigma: 2, offset: .init(0, 2)),
            caption: .init(png: caption as Data, rect: .init(x: 0, y: 72, width: 112, height: 16)))
        for encoding in [ExportEncoding.isoGainMapJPEG, .adaptive, .sdrTIFF, .pq] {
            let result = try await service.export(session: env.session.id, snapshot: env.snapshot(frame: frame),
                                                  request: env.request(encoding))
            let evidence = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
            let package = try JSONDecoder().decode(PackageReport.self, from: #require(evidence.packageJSON))
            #expect(package.verified && package.width == 112 && package.height == 88)
            if encoding == .adaptive {
                #expect(result.resolved.writer == .inHouse && result.resolved.writerReason == .frameGainProtection)
                #expect(evidence.writerReason == .frameGainProtection)
            }
            #expect(evidence.system.auxiliaryGain == encoding.writesGainMap)
            #expect(await env.sessions.exportThumbnail(env.session.id, export: result.record.id) != nil)
        }
    }

    @Test func realTransparentSourceIsCompositedOnLinearBlack() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let context = try #require(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 96*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        context.clear(CGRect(x: 0, y: 0, width: 48, height: 64))
        let pngURL = env.root.appendingPathComponent("transparent.png")
        let writer = try #require(CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(writer))
        let photo = try await env.sessions.open(pngURL)
        var recipe = Recipe(); recipe.setValue(.bool(false), for: "hdr.enabled")
        let snapshot = RecipeExportSnapshot(recipe: recipe, source: try .init(session: photo))
        let result = try await env.realService().export(session: photo.id, snapshot: snapshot, request: env.request(.sdrTIFF))
        let output = try #require(CIImage(contentsOf: result.file, options: [.expandToHDR: false]))
        let source = try #require(CIImage(contentsOf: pngURL, options: [.expandToHDR: false]))
        let expected = source.composited(over: CIImage(color: .black)).cropped(to: source.extent)
        let ci = CIContext(options: [.cacheIntermediates: false])
        let p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        func sample(_ image: CIImage, x: Int) -> [Float] {
            var values = [Float](repeating: 0, count: 4)
            values.withUnsafeMutableBytes { bytes in
                ci.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                          bounds: CGRect(x: x, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: p3)
            }
            return values
        }
        let clear = sample(output, x: 16)
        #expect(clear.prefix(3).allSatisfy { abs($0) < 0.001 })
        let actual = sample(output, x: 72), reference = sample(expected, x: 72)
        for c in 0..<3 { #expect(abs(actual[c] - reference[c]) < 0.002) }
    }

    @Test func realAuthoredRGBPairIsPreservedOrExplicitlyResplit() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let metadata = ExportGainMetadata(channelCount: 3, baseOffset: .init(repeating: 0.01),
                                          alternateOffset: .init(repeating: 0.02), alternateHeadroom: 4)
        let sourceResult = try await env.service(StripeFake(metadata: metadata, gainScale: 4)).export(
            session: env.session.id, snapshot: env.snapshot(), request: env.request(.isoGainMapJPEG))
        let sourceURL = env.root.appendingPathComponent("authored.jpg")
        try FileManager.default.copyItem(at: sourceResult.file, to: sourceURL)
        let photo = try await env.sessions.open(sourceURL)
        let recipe = Recipe(inputDomain: .dual)
        let revision = try RecipeSourceRevision(session: photo)
        let service = env.realService()
        func request(_ encoding: ExportEncoding) -> ExportPlanRequest {
            .init(choice: .custom(.init(encoding: encoding, gamut: .p3, quality: 95)),
                  source: .init(domain: .dual, pixelSize: .init(width: 96, height: 64)), edit: .init(peakStops: 4))
        }
        let kept = try await service.export(session: photo.id, snapshot: .init(recipe: recipe, source: revision),
                                             request: request(.isoGainMapJPEG))
        #expect(kept.resolved.gain?.channels == 3)
        #expect(kept.resolved.resplitReasons.isEmpty)
        #expect(kept.resolved.sourceProvenance == "authored")
        #expect(kept.resolved.provenance == "authored")
        let mono = try await service.export(session: photo.id, snapshot: .init(recipe: recipe, source: revision),
                                             request: request(.adaptive))
        // Adaptive also narrows the range upstream before the mono resplit.
        #expect(mono.resolved.sourceProvenance == "editedAuthored")
        #expect(mono.resolved.provenance == "resplit")
        let reopened = await env.sessions.exports(for: photo.id)
        let persisted = try #require(reopened.first { $0.id == mono.record.id }?.resolvedSnapshot)
        let decoded = try JSONDecoder().decode(ResolvedExportSnapshot.self, from: JSONEncoder().encode(persisted))
        #expect(decoded.sourceProvenance == "editedAuthored" && decoded.provenance == "resplit")
        #expect(mono.resolved.gain?.channels == 1)
        #expect(mono.resolved.resplitReasons.contains("writerCarriesOneChannel"))
        let social = ExportPlanRequest(choice: .destination(.social),
            source: .init(domain: .dual, pixelSize: .init(width: 96, height: 64)), edit: .init(peakStops: 4))
        let narrowed = try await service.export(session: photo.id, snapshot: .init(recipe: recipe, source: revision), request: social)
        #expect(narrowed.resolved.ceilingStops == 2)
        #expect((narrowed.resolved.gain?.alternateHeadroom ?? 0) <= 2)
        #expect(narrowed.resolved.resplitReasons.contains("outputCeiling"))
        #expect(narrowed.resolved.snapshot.recipe == recipe)
        let frame = FrameSnapshot(canvasSize: .init(width: 112, height: 88),
                                  photo: .init(x: 8, y: 8, width: 96, height: 64), paper: .init(repeating: 0.8))
        let framed = try await service.export(session: photo.id, snapshot: .init(recipe: recipe, source: revision, frame: frame),
                                               request: request(.isoGainMapJPEG))
        #expect(framed.resolved.gain?.baseOffset == .zero && framed.resolved.gain?.alternateOffset == .zero)
        #expect(framed.resolved.resplitReasons.contains("frameRequiresNeutralPair"))
        #expect(framed.resolved.sourceProvenance == "authored")
        #expect(framed.resolved.provenance == "resplit")
    }

    @Test func eightEncodingsArePackagedAndReadByBothReaders() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        for encoding in ExportEncoding.allCases {
            let result = try await env.service().export(session: env.session.id, snapshot: env.snapshot(), request: env.request(encoding))
            #expect(FileManager.default.fileExists(atPath: result.file.path))
            #expect(result.record.recipeSnapshot?.recipe == Recipe())
            #expect(result.record.resolvedSnapshot == result.resolved)
            let evidence = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
            if result.resolved.writer == .imageIO {
                #expect(evidence.packageJSON == nil && evidence.imageIO != nil && evidence.firstReaderJSON != nil)
            } else {
                let package = try JSONDecoder().decode(PackageReport.self, from: #require(evidence.packageJSON))
                #expect(package.schema == "hyperdr.package/v1")
                #expect(package.verified)
            }
            #expect(evidence.system.width == 96 && evidence.system.height == 64)
            #expect(evidence.system.auxiliaryGain == encoding.writesGainMap)
            #expect(await env.sessions.exportThumbnail(env.session.id, export: result.record.id) != nil)
        }
        #expect(await env.sessions.exports(for: env.session.id).count == 8)
    }

    /// Run each height in a fresh process. This isolates the Kit bridge/writer;
    /// verification is deliberately excluded until its bounded API lands.
    @Test func streamingHeightMemoryMeasurement() async throws {
        guard let value = ProcessInfo.processInfo.environment["HYPERDR_STREAM_HEIGHT"], let height = Int(value) else { return }
        let width = 2048, rows = 64
        let root = URL(fileURLWithPath: "/tmp/p7-stream-memory")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = try await Engine(configuration: .init(cacheDirectory: root.appendingPathComponent("cache")))
        let request = ExportRenderRequest(photoSize: .init(width: width, height: height), includesGain: false,
            capabilities: .init(supportsThreeChannelGain: false, supportsSignedGain: true,
                                requiresGainMaximumHeadroom: false))
        let fake = StripeFake()
        let bridge = PackageRowBridge(source: FakeRows(fake: fake, request: request, report: fake.report(request)), frame: nil)
        let file = root.appendingPathComponent("\(height).tif")
        try? FileManager.default.removeItem(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        _ = try await engine.packageRows(width: width, height: height, rows: rows, to: file,
            options: .init(format: "sdr-tiff", gamut: "p3", verify: false),
            read: { y, count, base, gain in try bridge.read(y: y, count: count, base: base, gain: gain) })
        _ = try bridge.thumbnail()
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        let data = try JSONSerialization.data(withJSONObject: ["height": height, "width": width, "rows": rows,
            "before": before.ru_maxrss, "peak": after.ru_maxrss], options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("\(height).json"))
        print("KIT_ROWS_MEMORY " + String(data: data, encoding: .utf8)!)
    }

    /// Fresh process per height; real system JPEG source, Render scan/ROI,
    /// Kit bridge and package. Record verification separately from row writing.
    @Test func realStreamingHeightMemoryMeasurement() async throws {
        guard let value = ProcessInfo.processInfo.environment["HYPERDR_STREAM_REAL_HEIGHT"],
              let height = Int(value), height > 0 else { return }
        let width = 2048, rows = 64
        let root = URL(fileURLWithPath: "/tmp/p7-stream-real-memory")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("source-\(height).jpg")
        let output = root.appendingPathComponent("output-\(height).tif")
        if !FileManager.default.fileExists(atPath: input.path) {
            try autoreleasepool {
                let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                for y in 0..<height {
                    context.setFillColor(CGColor(red: CGFloat(y % 127)/127, green: CGFloat(y)/CGFloat(height), blue: 0.4, alpha: 1))
                    context.fill(CGRect(x: 0, y: y, width: width, height: 1))
                }
                let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                    [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                #expect(CGImageDestinationFinalize(destination))
            }
        }
        // Generate in a separate invocation so its full-size CGContext does not
        // inflate this process's lifetime high-water mark.
        if ProcessInfo.processInfo.environment["HYPERDR_STREAM_REAL_GENERATE_ONLY"] == "1" { return }
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        func peak() -> Int { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return usage.ru_maxrss }
        let initialPeak = peak()
        let engine = try await Engine(configuration: .init(cacheDirectory: root.appendingPathComponent("cache")))
        let render = try RenderEngine()
        let source = try await render.openExportSource(input)
        let sourcePeak = peak()
        var recipe = Recipe(); recipe.setValue(.bool(false), for: "hdr.enabled")
        let request = ExportRenderRequest(photoSize: .init(width: width, height: height), includesGain: false,
            capabilities: .init(supportsThreeChannelGain: false, supportsSignedGain: true,
                                requiresGainMaximumHeadroom: false))
        let prepared = try await render.prepareRows(source, recipe: recipe, lut: nil, modelGain: nil,
            request: request, rows: rows)
        let preparedPeak = peak()
        // An arbitrary repeated band must be value-identical before encoding.
        let band = try prepared.read(y: height/2, count: min(rows, height-height/2))
        #expect(try prepared.read(y: height/2, count: min(rows, height-height/2)).baseRGB == band.baseRGB)
        let bridge = PackageRowBridge(source: prepared, frame: nil)
        let packaged = try await engine.packageRows(width: width, height: height, rows: rows, to: output,
            options: .init(format: "sdr-tiff", gamut: "p3", verify: true),
            read: { y, count, base, gain in try bridge.read(y: y, count: count, base: base, gain: gain) })
        _ = try bridge.thumbnail()
        #expect(packaged.verified)
        let nativeVerifiedPeak = peak()
        let plan = ExportPlanner.plan(ExportPlanRequest(choice: .custom(.init(encoding: .sdrTIFF, gamut: .p3, quality: 90)),
            source: .init(domain: .sdr, pixelSize: .init(width: width, height: height)),
            edit: .init(hdrEnabled: false, peakStops: 0)), budget: FixedExportMemoryBudget(bytes: 8_000_000_000))
        let system = try ExportVerification.system(output, plan: plan)
        #expect(system.width == width && system.height == height)
        let values: [String: Any] = ["width": width, "height": height, "rows": rows,
            "initialPeak": initialPeak, "sourcePeak": sourcePeak, "preparedPeak": preparedPeak,
            "nativeVerifiedPeak": nativeVerifiedPeak, "systemVerifiedPeak": peak()]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("\(height).json"))
        print("KIT_REAL_ROWS_MEMORY " + String(data: data, encoding: .utf8)!)
    }

    @Test(arguments: [false, true]) func pullWritersReplayRowsAndMatchWholePlanePixels(realRender: Bool) async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let calls = Mutex<[(Int, Int)]>([])
        let fake = StripeFake(onRead: { y, rows in calls.withLock { $0.append((y, rows)) } })
        let service = realRender ? env.realService() : env.service(fake)
        let frame = FrameSnapshot(canvasSize: .init(width: 112, height: 600),
            photo: .init(x: 8, y: 8, width: 96, height: 64), paper: .init(repeating: 0.8))
        func pixels(_ url: URL) throws -> [Float] {
            let image = try #require(CIImage(contentsOf: url, options: [.expandToHDR: true]))
            let w = Int(image.extent.width), h = Int(image.extent.height)
            var values = [Float](repeating: 0, count: w*h*4)
            values.withUnsafeMutableBytes { CIContext(options: [.cacheIntermediates: false]).render(image,
                toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: image.extent, format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)) }
            return values
        }
        for encoding in [ExportEncoding.sdrJPEG, .sdrTIFF, .isoGainMapJPEG, .adaptive, .pq, .hlg] {
            let snapshot = try env.snapshot(frame: encoding == .adaptive ? frame : nil)
            var request = env.request(encoding)
            let streamed = try await service.export(session: env.session.id, snapshot: snapshot, request: request)
            #expect(streamed.resolved.usesRowInput == true)
            request.allowsRowInput = false
            let whole = try await service.export(session: env.session.id, snapshot: snapshot, request: request)
            #expect(whole.resolved.usesRowInput == false)
            #expect(try pixels(streamed.file) == pixels(whole.file), "\(encoding)")
            #expect(await env.sessions.exportThumbnail(env.session.id, export: streamed.record.id) != nil)
        }
        let reads = calls.withLock { $0 }
        if realRender { return }
        #expect(reads.count > 6) // Gain analysis and encoding replay the same rows.
        #expect(reads.allSatisfy { $0.1 <= 256 })
        #expect(reads.filter { $0.0 == 0 }.count > 6)
    }

    @Test func heicMemoryFallbackKeepsEncodingQualityAndSize() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let request = env.request(.adaptive)
        let initial = ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: 1_000_000_000))
        let native = ExportMemoryEstimate.estimate(.init(source: request.source, photoSize: initial.photoSize,
            canvas: initial.size, encoding: .adaptive, writer: .inHouse, writesGainMap: true,
            isFramed: false, baseBitDepth: 8, writeRows: 256, retainedBytes: 0, quality: initial.quality))
        #expect(native.peak < initial.memory.estimate.peak)
        let result = try await env.service(budget: native.peak + 1).export(session: env.session.id,
            snapshot: env.snapshot(), request: request)
        #expect(result.resolved.writer == .inHouse && result.resolved.writerReason == .memoryFallback)
        #expect(result.resolved.encoding == .adaptive && result.resolved.bitDepth == 8)
        #expect(result.resolved.quality == initial.quality && result.resolved.width == initial.size.width
                && result.resolved.height == initial.size.height)
        let evidence = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
        #expect(evidence.writerReason == .memoryFallback && evidence.packageJSON != nil)
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
        #expect(evidence.system.verifiedHeadroomStops == [2])
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

    @Test func sourceRevisionRefreshesCachedModificationTime() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        // Prime the same URL resource cache before an mtime-only edit.
        let cached = try #require(env.session.sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let originalBytes = try Data(contentsOf: env.session.sourceURL)
        let changed = cached.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: env.session.sourceURL.path)
        let revision = try RecipeSourceRevision(session: env.session)
        #expect(revision.modificationTimeMilliseconds == Int64((changed.timeIntervalSince1970 * 1000).rounded()))
        #expect(revision.sha256 == env.session.sha256)
        #expect(try Data(contentsOf: env.session.sourceURL) == originalBytes)
    }

    @Test(arguments: [ExportEncoding.sdrJPEG, .avifPq]) func memoryFailureIncludesTheCheckAndMiBNumbers(encoding: ExportEncoding) async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let service = env.service(budget: 1)
        await #expect(throws: RecipeExportError.planBlocked(["export_memory_exceeded"])) {
            _ = try await service.export(session: env.session.id, snapshot: env.snapshot(), request: env.request(encoding))
        }
        let api: any RecipeExportServicing = service
        let diagnostic = try #require(await api.lastMemoryDiagnostic)
        #expect(diagnostic.reason == (encoding == .avifPq ? .nonIncrementalWriter : .workingSet))
        #expect(diagnostic.check == .process && diagnostic.phase == .planning)
        #expect(diagnostic.availableBytes == 1 && diagnostic.requiredBytes > 1)
        #expect(diagnostic.requiredMiB > diagnostic.availableMiB)
        #expect(diagnostic.summary.contains("check=process") && diagnostic.summary.contains("MiB"))
    }

    @Test func cancellationDiscardsPartialStripes() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let service = env.service(StripeFake(afterStripe: { throw CancellationError() }))
        await #expect(throws: CancellationError.self) {
            _ = try await service.export(session: env.session.id, snapshot: env.snapshot(), request: env.request(.sdrJPEG))
        }
        #expect(await env.sessions.exports(for: env.session.id).isEmpty)
    }

    @Test func runtimeMemoryRefusalCarriesAReplannedLongEdge() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let request = env.request(.isoGainMapJPEG)
        let initial = ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: 1_000_000_000))
        var smaller = request
        smaller.choice = .custom(.init(encoding: .isoGainMapJPEG, gamut: .p3, quality: 95, longEdge: 48))
        let smallerPlan = ExportPlanner.plan(smaller, budget: FixedExportMemoryBudget(bytes: 1_000_000_000))
        let resident = request.source.pixelSize.pixels * 16
        let available = smallerPlan.memory.estimate.peak - resident
        #expect(available > 0 && smallerPlan.memory.estimate.peak < initial.memory.estimate.peak)
        let budget = ChangingExportMemoryBudget(1_000_000_000)
        let service = RecipeExportService(engine: env.engine, renderEngine: env.render,
            renderer: StripeFake(before: { budget.bytes.withLock { $0 = available } }),
            sessions: env.sessions, target: env.target, budget: budget)
        do {
            _ = try await service.export(session: env.session.id, snapshot: env.snapshot(), request: request)
            Issue.record("Expected runtime memory admission to fail")
        } catch RecipeExportError.memoryExceeded(let reason) {
            guard case .memory(let needed, let measured, let size, let suggestion) = reason else {
                Issue.record("Expected a typed memory reason"); return
            }
            #expect(needed == initial.memory.estimate.peak - resident)
            #expect(measured == available && size == initial.size)
            let edge = try #require(suggestion)
            #expect(edge < initial.photoSize.longEdge)
            #expect(edge == ExportPlanner.maximumLongEdge(request, budget: available + resident, upper: initial.photoSize.longEdge))
            smaller.choice = .custom(.init(encoding: .isoGainMapJPEG, gamut: .p3, quality: 95, longEdge: edge))
            #expect(ExportPlanner.plan(smaller, budget: FixedExportMemoryBudget(bytes: available + resident)).memory.fits)
        }
        #expect(await env.sessions.exports(for: env.session.id).isEmpty)
    }

    @Test(arguments: [false, true]) func replanningCreditsTheSourceWhenRemainingMemoryDrops(rows: Bool) async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var request = env.request(.isoGainMapJPEG)
        request.allowsRowInput = rows
        let initialPlan = ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: 1_000_000_000))
        let peak = initialPlan.memory.estimate.peak
        let sourceBytes = request.source.pixelSize.pixels * 16
        let budget = ChangingExportMemoryBudget(peak + 1)
        let renderer: any ExportStripeRendering = rows ? StripeFake() : env.render
        let service = RecipeExportService(engine: env.engine, renderEngine: env.render, renderer: renderer,
            sessions: env.sessions, target: env.target, budget: budget)
        let preparations = Mutex(0)
        let result = try await service.export(session: env.session.id, snapshot: env.snapshot(), request: request,
            progress: { event in
                if event.stage == .preparing && preparations.withLock({ $0 += 1; return $0 == 2 }) {
                    budget.bytes.withLock { $0 -= sourceBytes }
                }
            })
        #expect(budget.availableBytes() == peak + 1 - sourceBytes)
        #expect(result.record.resolvedSnapshot == result.resolved)
        #expect(result.resolved.width == 96 && result.resolved.height == 64)
        // A remaining budget below the genuinely incremental peak still refuses.
        budget.bytes.withLock { $0 = peak + 1 }
        preparations.withLock { $0 = 0 }
        do {
            _ = try await service.export(session: env.session.id, snapshot: env.snapshot(), request: request,
                progress: { event in
                    if event.stage == .preparing && preparations.withLock({ $0 += 1; return $0 == 2 }) {
                        budget.bytes.withLock { $0 = peak - sourceBytes - 1 }
                    }
                })
            Issue.record("Runtime replan should refuse the smaller budget")
        } catch RecipeExportError.memoryExceeded(let reason) {
            guard case .memory(let needed, let available, let size, _) = reason else {
                Issue.record("Expected a typed memory reason"); return
            }
            #expect(needed > available)
            #expect(available == peak - sourceBytes - 1)
            #expect(size == initialPlan.size)
        }
        #expect(await env.sessions.exports(for: env.session.id).count == 1)
    }

    @Test func defaultProviderResolvesSelectionAndChecksHistoricalIdentity() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var recipe = Recipe(); recipe.setHDRSource(.ai)
        let snapshot = try env.snapshot(recipe: recipe)
        #expect(snapshot.modelSelection == "research-cnn-v1")
        #expect(snapshot.expectedModelIdentity == nil)
        let service = env.realService()
        let result = try await service.export(session: env.session.id, snapshot: snapshot, request: env.request(.isoGainMapJPEG))
        let identity = try #require(result.resolved.modelIdentity)
        #expect(identity.hasPrefix("research-cnn-v1/"))
        #expect(identity.contains("/features-v1/analysis-1024"))
        #expect(result.record.resolvedSnapshot?.modelIdentity == identity)
        let decoded = try JSONDecoder().decode(ResolvedExportSnapshot.self, from: JSONEncoder().encode(result.resolved))
        #expect(decoded.modelIdentity == identity)
        let plan = ExportPlanner.plan(env.request(.isoGainMapJPEG), budget: FixedExportMemoryBudget(bytes: 1_000_000_000))
        let a = ResolvedExportSnapshot(snapshot: snapshot, plan: plan, modelIdentity: identity)
        let b = ResolvedExportSnapshot(snapshot: snapshot, plan: plan, modelIdentity: identity + "/different-version")
        #expect(try a.exportKey() != b.exportKey())
        _ = try await service.export(session: env.session.id,
            snapshot: env.snapshot(recipe: recipe, modelID: identity), request: env.request(.isoGainMapJPEG))
        await #expect(throws: RecipeExportError.missingModel) {
            _ = try await service.export(session: env.session.id,
                snapshot: env.snapshot(recipe: recipe, modelID: identity + "/wrong-version"), request: env.request(.isoGainMapJPEG))
        }
        recipe.setValue(.string("unknown-model"), for: "hdr.model")
        await #expect(throws: RecipeExportError.missingModel) {
            _ = try await service.export(session: env.session.id,
                snapshot: env.snapshot(recipe: recipe), request: env.request(.isoGainMapJPEG))
        }
        #expect(await env.sessions.exports(for: env.session.id).count == 2)
    }

    @Test func realAutoAIRangeIsResolvedAfterPrediction() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var recipe = Recipe(); recipe.setHDRSource(.ai)
        let ready = Mutex(false)
        let predictedStops = Mutex<Float>(2)
        let service = env.realService(prediction: { source, model in
            try await Task.sleep(for: .milliseconds(10))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 8, height: 8, mipmapped: false)
            descriptor.storageMode = .shared
            let device = try #require(MTLCreateSystemDefaultDevice())
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            let values = [Float](repeating: predictedStops.withLock { $0 }, count: 64)
            values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0,
                                                     withBytes: $0.baseAddress!, bytesPerRow: 8 * 4) }
            ready.withLock { $0 = true }
            #expect(model == "research-cnn-v1")
            return .init(sourceID: source.id, modelID: "test-v1", gain: texture)
        })
        // Both pre-inference readouts used to override the frozen auto Recipe.
        for placeholder in [0.0, 0.5] {
            var request = env.request(.isoGainMapJPEG)
            request.edit.peakStops = placeholder
            let result = try await service.export(session: env.session.id,
                snapshot: env.snapshot(recipe: recipe, modelID: "test-v1"), request: request)
            #expect(ready.withLock { $0 })
            #expect(abs((result.resolved.ceilingStops ?? 0) - 2) < 0.01)
            #expect(abs((result.resolved.rangeBeforeCeiling ?? 0) - 2) < 0.01)
            #expect(result.resolved.rangeBeforeCeiling == result.resolved.rangeAfterCeiling)
            #expect(abs((result.resolved.resolvedAutomatic["hdr.range"] ?? 0) - 2) < 0.01)
            #expect((result.resolved.gain?.alternateHeadroom ?? 0) > 1.9)
            #expect(!result.resolved.resplitReasons.contains("outputCeiling"))
        }
        predictedStops.withLock { $0 = 3 }
        let social = ExportPlanRequest(choice: .destination(.social),
            source: .init(domain: .sdr, pixelSize: .init(width: 96, height: 64)), edit: .init(peakStops: 0))
        let limited = try await service.export(session: env.session.id,
            snapshot: env.snapshot(recipe: recipe, modelID: "test-v1"), request: social)
        #expect(limited.resolved.ceilingStops == 2)
        #expect(abs((limited.resolved.rangeBeforeCeiling ?? 0) - 3) < 0.01)
        #expect(limited.resolved.rangeAfterCeiling == 2)
        #expect(limited.resolved.resplitReasons.contains("outputCeiling"))
        recipe.setValue(.number(1), for: "hdr.range")
        let manual = try await service.export(session: env.session.id,
            snapshot: env.snapshot(recipe: recipe, modelID: "test-v1"), request: env.request(.isoGainMapJPEG))
        #expect(manual.resolved.ceilingStops == 1)
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
            #expect(model == "research-cnn-v1")
            return .init(sourceID: source.id, modelID: "test-v1", gain: texture)
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

@Suite("Row writer progress")
struct RowWriterProgressTests {
    @Test func serviceExportsTheSelectedLongEdgeAndCombinedProgress() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var request = env.request(.isoGainMapJPEG)
        request.choice = .custom(.init(encoding: .isoGainMapJPEG, quality: 95, longEdge: 48))
        let events = Mutex<[RecipeExportProgress]>([])
        let result = try await env.service().export(session: env.session.id, snapshot: env.snapshot(), request: request,
            progress: { event in events.withLock { $0.append(event) } })
        #expect(result.resolved.width == 48 && result.resolved.height == 32)
        #expect(result.resolved.selection.customFormat?.longEdge == 48)
        #expect(events.withLock { $0.contains { $0.includesRendering && $0.totalRows == 32 } })
        #expect(!events.withLock { $0.contains { $0.stage == .developing } })
    }

    @Test func replayReportsDistinctPassesWithoutDuplicateRows() throws {
        let request = ExportRenderRequest(photoSize: .init(width: 8, height: 8), includesGain: false,
            capabilities: .init(supportsThreeChannelGain: false, supportsSignedGain: true,
                                requiresGainMaximumHeadroom: false))
        let fake = StripeFake()
        let events = Mutex<[RecipeExportProgress]>([])
        let bridge = PackageRowBridge(source: FakeRows(fake: fake, request: request, report: fake.report(request)),
            frame: nil, progress: { event in events.withLock { $0.append(event) } })
        var base = [Float](repeating: 0, count: 8 * 4 * 3)
        for y in [0, 0, 4, 0, 4] {
            try base.withUnsafeMutableBufferPointer { try bridge.read(y: y, count: 4, base: $0, gain: nil) }
        }
        let actual = events.withLock { $0 }
        #expect(actual.map(\.completedRows) == [4, 8, 4, 8])
        #expect(actual.map(\.rowPass) == [1, 1, 2, 2])
        #expect(actual[0].stageMessage.localized(locale: Locale(identifier: "en")) == "Rendering and encoding")
        #expect(actual[0].stageMessage.localized(locale: Locale(identifier: "zh-Hans")) == "渲染与编码")
        #expect(actual.allSatisfy { $0.stage == .encoding && $0.includesRendering && $0.totalRows == 8 })
        _ = try bridge.thumbnail()
    }
}
