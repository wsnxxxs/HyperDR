import XCTest
import HyperDRKit
@testable import HyperDR

/// Dragging an export version out and sharing it (T7-2): which versions can be
/// handed over, what the receiver is told the file is called, and how a failed
/// copy is reported.
@MainActor final class ExportTransferTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/tmp/first.jpg")
    private let second = URL(fileURLWithPath: "/tmp/second.jpg")

    private func ready() async -> (EditorModel, FakeEditorServices) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        let model = EditorModel(services: services, ticker: ManualFrameTicker())
        await model.loadExportServices()
        model.open([source])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        return (model, services)
    }

    private func result(_ id: String, name: String = "result.heic", saved: String? = nil) -> ExportResult {
        var r = ExportResult(export: id, fileName: name, byteCount: 100, pixelSize: PixelSize(width: 6000, height: 4000))
        if let saved { r.saved = SavedLocation(fileName: saved, folderLabel: "…/Pictures") }
        return r
    }

    private func list(_ model: EditorModel, _ services: FakeEditorServices, _ versions: [ExportVersion]) async throws {
        let key = try await services.exportKey(model.photo!, options: model.effectiveOptions(), frame: nil)
        services.historyByURL[source] = versions.map { ExportHistoryItem(version: $0, key: key, options: model.edit) }
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.exportVersions.count == versions.count }
    }

    func testAVersionWhoseFileIsGoneCannotBeHandedOver() async throws {
        let (m, s) = await ready()
        try await list(m, s, [
            ExportVersion(number: 2, createdAt: Date(), encodingID: "adaptive", fileAvailable: false, result: result("v2")),
            ExportVersion(number: 1, createdAt: Date(), encodingID: "adaptive", result: result("v1")),
        ])
        XCTAssertNil(m.transferItem(for: "v2"))
        XCTAssertNotNil(m.transferItem(for: "v1"))
        XCTAssertNil(m.transferItem(for: "nothing"))
    }

    func testTheReceiverSeesTheSavedNameElseTheRecordName() async throws {
        let (m, s) = await ready()
        try await list(m, s, [
            ExportVersion(number: 2, createdAt: Date(), encodingID: "adaptive", result: result("v2", saved: "Holiday.heic")),
            ExportVersion(number: 1, createdAt: Date(), encodingID: "adaptive", result: result("v1")),
        ])
        XCTAssertEqual(m.transferItem(for: "v2")?.fileName, "Holiday.heic")
        XCTAssertEqual(m.transferItem(for: "v1")?.fileName, "result.heic")
    }

    func testStagingAsksTheServiceForThatVersionUnderThatNameAndClearsEarlierFailure() async throws {
        let (m, s) = await ready()
        try await list(m, s, [ExportVersion(number: 1, createdAt: Date(), encodingID: "adaptive", result: result("v1", saved: "Holiday.heic"))])
        let staged = URL(fileURLWithPath: "/tmp/staged/Holiday.heic")
        s.transferHandler = { _, _ in staged }
        m.reportTransferFailure(version: "v1", fileName: "Holiday.heic", error: UserFacingError(code: "source_missing"))
        let url = try await m.transferItem(for: "v1")!.stage()
        XCTAssertEqual(url, staged)
        XCTAssertEqual(s.transferCalls.count, 1)
        XCTAssertEqual(s.transferCalls.first?.0, "v1")
        XCTAssertEqual(s.transferCalls.first?.1, "Holiday.heic")
        XCTAssertNil(m.export.transferFailure)
    }

    func testAFailedCopyIsReportedWithTheVersionAndNameAndRethrown() async throws {
        let (m, s) = await ready()
        try await list(m, s, [ExportVersion(number: 1, createdAt: Date(), encodingID: "adaptive", result: result("v1"))])
        s.transferHandler = { _, _ in throw UserFacingError(code: "source_missing") }
        do { _ = try await m.transferItem(for: "v1")!.stage(); XCTFail("should throw") } catch {}
        XCTAssertEqual(m.export.transferFailure?.version, "v1")
        XCTAssertEqual(m.export.transferFailure?.fileName, "result.heic")
        XCTAssertEqual(m.export.transferFailure?.error.code, "source_missing")
    }

    func testOpeningAnotherPhotoForgetsTheFailure() async throws {
        let (m, s) = await ready()
        _ = s
        m.reportTransferFailure(version: "v1", fileName: "a.heic", error: UserFacingError(code: "source_missing"))
        m.open([second])
        await eventually(timeout: .seconds(10)) { m.photo?.url == self.second && !m.suggestedFileName.isEmpty }
        XCTAssertNil(m.export.transferFailure)
    }
}
