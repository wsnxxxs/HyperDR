import CoreImage
import Foundation
import Darwin
import CryptoKit
import Metal
import XCTest
import HyperDRRecipe
@testable import HyperDRRender

/// Explicit local investigation; normal tests never depend on personal photos.
final class RAWAnalysisProbeTests: XCTestCase {
    func testFixedAnalysisDevelopmentProbe() async throws {
        guard let path = ProcessInfo.processInfo.environment["HYPERDR_RAW_ANALYSIS_PROBE"] else {
            throw XCTSkip("Set HYPERDR_RAW_ANALYSIS_PROBE to investigate RAW analysis")
        }
        let url = URL(fileURLWithPath: path)
        let decoder = ProcessInfo.processInfo.environment["HYPERDR_RAW_ANALYSIS_DECODER"] ?? "9"
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        guard filter.supportedDecoderVersions.contains(where: { $0.rawValue == decoder }) else {
            throw XCTSkip("Requested decoder unavailable")
        }
        let engine = try RenderEngine()
        try await engine.probeFixedRAWAnalysis(url, decoder: decoder)
    }
}

extension RenderEngine {
    fileprivate func probeFixedRAWAnalysis(_ url: URL, decoder: String) async throws {
        let clock = ContinuousClock()
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = clock.now
            let value = try body()
            let d = start.duration(to: clock.now).components
            print("RAW_ANALYSIS \(decoder) \(name)=\(Double(d.seconds) + Double(d.attoseconds) / 1e18)")
            return value
        }
        func timedAsync<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
            let start = clock.now
            let value = try await body()
            let d = start.duration(to: clock.now).components
            print("RAW_ANALYSIS \(decoder) \(name)=\(Double(d.seconds) + Double(d.attoseconds) / 1e18)")
            return value
        }
        let options = try SourceOptions(recipe: Recipe(inputDomain: .rawEDR, rawDecoderVersion: decoder),
            resolution: .preview(maximumSize: PixelSize(width: 1280, height: 1280)))
        if let mode = ProcessInfo.processInfo.environment["HYPERDR_RAW_ANALYSIS_MODE"] {
            let began = clock.now
            let source = try await timedAsync("mode_\(mode)_load") {
                try await load(url, options: options, preparingAnalysis: mode == "shared") { phase in
                    print("RAW_ANALYSIS_PHASE \(phase) elapsed=\(began.duration(to: clock.now))")
                }
            }
            let fixed = try timed("mode_fixed") { try fixedAnalysisSource(source) }
            let analysis = try timed("mode_GPU_analysis") { try self.analysis(source) }
            print("RAW_ANALYSIS_TOTAL \(mode) \(began.duration(to: clock.now))")
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF, &usage)
            print("RAW_ANALYSIS_MAX_RSS_BYTES \(usage.ru_maxrss)")
            for (name, texture) in [("preview", source.texture), ("fixed", fixed.texture), ("cells", analysis.cells),
                                    ("masks", analysis.masks), ("expansion", analysis.expansion)] {
                let values = Self.readTexture(texture)
                let hash = values.withUnsafeBytes { SHA256.hash(data: Data($0)) }
                print("RAW_ANALYSIS_HASH \(name) \(hash)")
            }
            return
        }
        let preview = try await timedAsync("preview_load") { try await load(url, options: options) }
        let fixed = try timed("fixed_reopen_and_materialize") { try fixedAnalysisSource(preview) }
        let spatial = try timed("analysis_GPU_after_fixed") { try analysis(preview) }
        _ = try timed("source_report_cached") { try sourceReport(preview) }
        print("RAW_ANALYSIS sizes native=\(preview.nativeSize) preview=\(preview.size) fixed=\(fixed.size) cells=\(spatial.size)")

        // Control: same canonical analysis obtained by the export entry point.
        let export = try await timedAsync("export_open_with_fixed") { try await openExportSource(url, options: options) }
        XCTAssertEqual(Self.readTexture(fixed.texture), Self.readTexture(export.analysisSource.texture))
        let exportSpatial = try analysis(export.analysisSource)
        XCTAssertEqual(Self.readTexture(spatial.cells), Self.readTexture(exportSpatial.cells))
        XCTAssertEqual(spatial.peaks, exportSpatial.peaks)

        // Investigate sharing one native graph without changing either ROI grid.
        let graph = try timed("shared_graph_setup") { try Self.openRAW(url, options: options) }
        _ = try timed("shared_graph_preview") {
            try rasterizeRAWPreview(graph.image, size: preview.size, space: Self.workingColorSpace)
        }
        let shared = try timed("shared_graph_fixed") {
            try rasterizeRAWPreview(graph.image, size: fixed.size, space: Self.workingColorSpace)
        }
        let canonical = Self.readTexture(fixed.texture), reused = Self.readTexture(shared)
        let sharedError = zip(canonical, reused).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        print("RAW_ANALYSIS shared_graph_fixed_max_error=\(sharedError)")

        // A tempting shortcut, deliberately NOT installed as the analysis source.
        let reduced = try timed("downsample_materialized_preview") {
            try rasterizeRAWPreview(preview.hdrImage, size: fixed.size, space: Self.workingColorSpace)
        }
        let shortcut = Self.readTexture(reduced)
        var maxError: Float = 0, meanError: Double = 0, differing = 0
        for i in canonical.indices where i % 4 != 3 {
            let error = abs(canonical[i] - shortcut[i])
            maxError = max(maxError, error)
            meanError += Double(error)
            if error != 0 { differing += 1 }
        }
        print("RAW_ANALYSIS preview_shortcut max_linear=\(maxError) mean_linear=\(meanError / Double(canonical.count / 4 * 3)) differing_channels=\(differing)")

        func footprints(_ size: PixelSize) -> (tiles: Int, pixels: Int) {
            let bounds = graph.image.extent.integral, limit = PreparedExportRows.maximumSourceTileSize
            let sx = bounds.width / Double(size.width), sy = bounds.height / Double(size.height)
            let columns = max(1, Int(Double(limit.width - 6) / sx))
            let rows = max(1, Int(Double(limit.height - 6) / sy))
            var tiles = 0, pixels = 0
            for y in stride(from: 0, to: size.height, by: rows) {
                for x in stride(from: 0, to: size.width, by: columns) {
                    let roi = CGRect(x: Double(x) * sx, y: Double(y) * sy,
                        width: Double(min(columns, size.width-x)) * sx,
                        height: Double(min(rows, size.height-y)) * sy)
                        .insetBy(dx: -1, dy: -1).integral.intersection(CGRect(origin: .zero, size: bounds.size))
                    tiles += Int(ceil(roi.width / Double(limit.width))) * Int(ceil(roi.height / Double(limit.height)))
                    pixels += Int(roi.width) * Int(roi.height)
                }
            }
            return (tiles, pixels)
        }
        print("RAW_ANALYSIS native_footprints preview=\(footprints(preview.size)) fixed=\(footprints(fixed.size))")
    }
}
