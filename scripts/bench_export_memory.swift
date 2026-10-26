// Release-only local export footprint probe. Run one case per fresh process.
// Build as an executable depending on HyperDRKit/Render/Recipe/Engine, then:
// bench_export_memory INPUT ENCODING OUTPUT [none|FILM_STRENGTH] [live-editor]
// Optional environment: HYPERDR_BENCH_QUALITY (90),
// HYPERDR_BENCH_BUDGET_BYTES (2000000000), HYPERDR_BENCH_RANGE_STOPS (2;
// use "auto" for the default recipe). under2GB always uses decimal 2 GB.
// HYPERDR_BENCH_EFFECTS sets grain and halation in recipe percent (default 0).
// HYPERDR_BENCH_HDR overrides the HDR switch (0/1; default off for SDR formats).
// The 2 GB gate is decimal bytes, not 2 GiB. This is not a device guarantee:
// run the same recipe on iPhone to validate Apple's device decoder as well.
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import HyperDRRecipe
import HyperDRRender
import HyperDREngine
import HyperDRKit

private func footprint() -> (current: UInt64, peak: UInt64) {
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &vm) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? (vm.phys_footprint, UInt64(max(0, vm.ledger_phys_footprint_peak))) : (0, 0)
}

@main struct ExportMemoryBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4, let encoding = ExportEncoding(rawValue: args[2]) else {
            throw NSError(domain: "ExportMemoryBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Usage: bench_export_memory INPUT ENCODING OUTPUT [none|FILM_STRENGTH] [live-editor]"])
        }
        let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[3])
        guard let image = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { throw RenderError.cannotOpenSource }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let size = PixelSize(width: orientation >= 5 ? height : width, height: orientation >= 5 ? width : height)
        let raw = ["arw", "dng", "rwl", "cr2", "cr3", "nef", "raf"].contains(input.pathExtension.lowercased())
        let domain: InputDomain = raw ? .rawEDR : .sdr
        let render = try RenderEngine()
        var recipe = Recipe(inputDomain: domain)
        if raw { recipe.rawDecoderVersion = await render.preferredRAWDecoder(input) }
        let range = ProcessInfo.processInfo.environment["HYPERDR_BENCH_RANGE_STOPS"] ?? "2"
        if let stops = Double(range) { recipe.setValue(.number(stops), for: "hdr.range") }
        let hdrEnabled = ProcessInfo.processInfo.environment["HYPERDR_BENCH_HDR"]
            .map { $0 != "0" } ?? !encoding.isSDR
        recipe.setValue(.bool(hdrEnabled), for: "hdr.enabled")
        let strength = args.count > 4 ? Double(args[4]) : nil
        if let strength {
            recipe.setValue(.string("portra400"), for: Recipe.filmID)
            recipe.setValue(.number(strength), for: "look.filmStrength")
            recipe.setValue(.number(0), for: Recipe.filmExposureID)
            // Recipe defaults are zero; choosing a stock in the UI applies 100 %.
            if let effects = ProcessInfo.processInfo.environment["HYPERDR_BENCH_EFFECTS"].flatMap(Double.init) {
                recipe.setValue(.number(effects), for: "effect.grain")
                recipe.setValue(.number(effects), for: "effect.halation")
            }
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("export-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = KitConfiguration(supportDirectory: temp.appendingPathComponent("support"),
                                      cacheDirectory: temp.appendingPathComponent("cache"))
        let engine = try await Engine(configuration: .init(cacheDirectory: config.cacheDirectory))
        let sessions = SessionStore(configuration: config, formats: InputFormats())
        let session = try await sessions.open(input)
        // Keep a real preview source, frame and renderer alive beside the export.
        let editor = args.contains("live-editor") ? try RenderEngine() : nil
        let preview: RenderSource?
        let frame: RenderPlanes?
        if let editor {
            let source = try await editor.load(input, options: SourceOptions(recipe: recipe,
                resolution: .preview(maximumSize: .init(width: 2048, height: 2048))), preparingAnalysis: true)
            preview = source
            frame = try await editor.render(source, recipe: recipe)
        } else { preview = nil; frame = nil }
        let environment = ProcessInfo.processInfo.environment
        let cap = environment["HYPERDR_BENCH_BUDGET_BYTES"].flatMap(Int.init) ?? 2_000_000_000
        let quality = environment["HYPERDR_BENCH_QUALITY"].flatMap(Int.init) ?? 90
        let request = ExportPlanRequest(choice: .custom(.init(encoding: encoding, gamut: .p3, quality: quality)),
            source: .init(domain: domain, pixelSize: .init(width: size.width, height: size.height)),
            edit: .init(recipe: recipe, peakStops: 2))
        let plan = ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: cap))
        let service = RecipeExportService(engine: engine, renderEngine: render, renderer: render, sessions: sessions,
            target: ExportTarget(configuration: config, sessions: sessions), budget: FixedExportMemoryBudget(bytes: cap))
        let snapshot = try RecipeExportSnapshot(recipe: recipe, source: RecipeSourceRevision(session: session))
        let before = footprint(), start = ContinuousClock.now
        let result = try await service.export(session: session.id, snapshot: snapshot, request: request)
        let duration = start.duration(to: .now).components
        let after = footprint()
        // Make the intended resident owners' lifetime explicit through the measurement.
        withExtendedLifetime((editor, preview, frame)) {}
        let report = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
        try FileManager.default.copyItem(at: result.file, to: output)
        let record: [String: Any] = [
            "encoding": encoding.rawValue, "quality": quality, "budgetBytes": cap, "width": size.width, "height": size.height,
            "filmStrength": strength as Any? ?? "none", "rangeStops": range, "liveEditor": editor != nil,
            "hdrEnabled": hdrEnabled, "needsLookBaseline": recipe.needsLookBaseline(includesHDR: plan.includesHDR),
            "effects": ProcessInfo.processInfo.environment["HYPERDR_BENCH_EFFECTS"] ?? "0",
            "decoder": recipe.rawDecoderVersion ?? "none", "verified": result.verified,
            "usesRowInput": report.usesRowInput ?? false, "estimateBytes": plan.memory.estimate.peak,
            "startFootprintBytes": before.current, "peakFootprintBytes": after.peak,
            "endFootprintBytes": after.current, "under2GB": after.peak > 0 && after.peak <= 2_000_000_000,
            "seconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
            "stages": report.stageSeconds, "outputBytes": result.byteCount
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
    }
}
