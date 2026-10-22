import AppKit
import SwiftUI
import XCTest
import HyperDRDesign
import HyperDRRecipe
import HyperDRRender
@testable import HyperDR

/// The whole inspector column, in the app (real model, real catalogue), in
/// light and dark, English and Chinese, for the three states of the design
/// (docs/design/apple/m2-inspector-*.png): HDR enhancement with manual
/// controls, AI enhancement, colour-only with the waveform. Each render has
/// to have something on it; with $HDR_SNAPSHOT_DIR set the pictures are also
/// written (to the host's temporary folder) as `m2v-inspector-<state>-<variant>.png`.
@MainActor final class InspectorSnapshotTests: XCTestCase {
    private let variants: [(name: String, scheme: ColorScheme, locale: String)] = [
        ("light", .light, "en"), ("dark", .dark, "en"),
        ("light-zh-Hans", .light, "zh-Hans"), ("dark-zh-Hans", .dark, "zh-Hans"),
    ]

    private func open(domain: HyperDRRecipe.InputDomain = .sdr, holdingPredictions: Bool = false) async -> EditorModel {
        let services = FakeEditorServices(openDelay: .zero)
        let url = URL(fileURLWithPath: "/fixtures/DSC00123.jpg")
        await services.fakeRendering?.configure { $0.photos[url] = .init(domain: domain) }
        if holdingPredictions { await services.fakeRendering?.holdPredictions() }
        let model = EditorModel(services: services)
        model.open([url])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        model.scopes.update(original: .some(Self.histogram(peak: 0.3)), current: .some(Self.histogram(peak: 0.45)),
                            waveform: .some(Self.waveform()))
        return model
    }

    /// A smooth synthetic histogram: two humps, one in the SDR part and one above SDR white.
    private static func histogram(peak: Double) -> HistogramData {
        let bins = HistogramData.bins
        func curve(_ shift: Double) -> [UInt32] {
            (0..<bins).map { bin in
                let x = Double(bin) / Double(bins)
                let hump = exp(-pow((x - peak) / 0.12, 2)) + 0.5 * exp(-pow((x - (peak + shift)) / 0.07, 2))
                    + (x > 0.7 ? 0.18 * exp(-pow((x - 0.8) / 0.05, 2)) : 0)
                return UInt32(hump * 40_000)
            }
        }
        return HistogramData(total: 1_000_000, luma: curve(0.2), red: curve(0.25), green: curve(0.2), blue: curve(0.15))
    }

    private static func waveform() -> WaveformData {
        let columns = 160, rows = WaveformData.rows
        var counts = [UInt32](repeating: 0, count: columns * rows)
        for column in 0..<columns {
            let centre = 0.3 + 0.18 * sin(Double(column) / 14) + (column > 110 ? 0.4 : 0)
            for row in 0..<rows {
                let y = Double(row) / Double(rows)
                counts[row * columns + column] = UInt32(900 * exp(-pow((y - centre) / 0.06, 2)))
            }
        }
        return WaveformData(columns: columns, counts: counts)
    }

    private func render(_ model: EditorModel, scheme: ColorScheme, locale: String,
                        session: ViewerSessionState) throws -> NSBitmapImageRep {
        let root = InspectorContent(model: model)
            .frame(width: Layout.inspectorWidth)
            .background(Color.hdr.surfacePanel)
            .fixedSize(horizontal: false, vertical: true)
            .environment(session)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: locale))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func distinctColours(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(bitmap.pixelsWide / 97, 1), stepY = max(bitmap.pixelsHigh / 89, 1)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return seen.count
    }

    /// Where the pictures go when asked for with `$HDR_SNAPSHOT_DIR` (as
    /// `TEST_RUNNER_HDR_SNAPSHOT_DIR` under xcodebuild). The test host is
    /// sandboxed, so this is a folder inside its container, named by the
    /// value's last component; the test log prints the path.
    private static let snapshotDirectory: URL? = {
        guard let name = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("snapshots are written to \(directory.path)")
        return directory
    }()

    /// Renders every variant of one state, checks it, and returns the pictures by variant.
    private func snapshots(_ state: String, model: EditorModel, configure: (ViewerSessionState) -> Void)
        throws -> [String: Data] {
        let directory = Self.snapshotDirectory
        var pictures: [String: Data] = [:]
        for variant in variants {
            let session = ViewerSessionState()
            configure(session)
            let bitmap: NSBitmapImageRep
            bitmap = try render(model, scheme: variant.scheme, locale: variant.locale, session: session)
            XCTAssertGreaterThan(distinctColours(bitmap), 40, "\(state) \(variant.name) is blank")
            XCTAssertGreaterThan(bitmap.pixelsHigh, 600, "\(state) \(variant.name) has no content below the scope")
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            pictures[variant.name] = data
            if let directory {
                try data.write(to: directory.appendingPathComponent("m2v-inspector-\(state)-\(variant.name).png"))
            }
        }
        XCTAssertEqual(Set(pictures.values).count, 4, "\(state): light, dark, English and Chinese differ")
        return pictures
    }

    func testHDRManualWhileDragging() async throws {
        let model = await open()
        let strength = try XCTUnwrap(Adjustments.declaration("hdr.strength"))
        model.editor.editingChanged(strength, true)
        await model.editor.settle()
        _ = try snapshots("hdr-manual", model: model) { _ in }
        model.editor.editingChanged(strength, false)
        model.closeDocument()
    }

    /// The AI source while its prediction is computed: the photo shows
    /// without AI and the status line says so (p7-2b §14.3).
    func testAIPredicting() async throws {
        let model = await open(holdingPredictions: true)
        var recipe = model.editor.recipe
        recipe.setValue(.string("ai"), for: "hdr.source")
        model.editor.setRecipe(recipe)
        await eventually { model.editor.isModelGainPending }
        let pictures = try snapshots("ai-predicting", model: model) { $0.isScopeExpanded = false }
        XCTAssertFalse(pictures.isEmpty)
        await (model.services as? FakeEditorServices)?.fakeRendering?.releasePredictions()
        model.closeDocument()
    }

    func testWaveform() async throws {
        let model = await open()
        _ = try snapshots("waveform", model: model) { $0.scopeKind = .waveform }
        model.closeDocument()
    }
}
