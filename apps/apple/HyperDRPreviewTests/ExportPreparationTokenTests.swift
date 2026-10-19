import XCTest
@testable import HyperDR

@MainActor final class ExportPreparationTokenTests: XCTestCase {
    private func ready() async -> (EditorModel, FakeEditorServices) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        let model = EditorModel(services: services)
        await model.loadExportServices()
        model.open([URL(fileURLWithPath: "/tmp/first.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        return (model, services)
    }
    private let destination = URL(fileURLWithPath: "/tmp/result.heic")

    func testReviewerChosenDestinationCannotExportANewPhoto() async throws {
        let (model, services) = await ready()
        let token = try XCTUnwrap(model.prepareExport())
        let completion: (URL) -> Void = { model.startExport(destination: $0, token: token) }
        let second = URL(fileURLWithPath: "/tmp/second.jpg")
        model.open([second])
        await eventually(timeout: .seconds(3)) { model.photo?.url == second && model.document?.phase == .ready }
        completion(destination)
        XCTAssertNil(model.exportTask, "Rejection is synchronous, before an export task can be scheduled")
        XCTAssertTrue(services.exportCalls.isEmpty)
        XCTAssertEqual(model.export.phase, .idle); XCTAssertNil(model.alert)
    }

    func testTokenInvalidatesAtSwitchStartEvenIfOpeningIsCancelled() async throws {
        let (model, services) = await ready()
        let token = try XCTUnwrap(model.prepareExport())
        model.open([URL(fileURLWithPath: "/tmp/second.jpg")])
        XCTAssertNil(model.pendingExportToken)
        model.cancelOpen()
        model.startExport(destination: destination, token: token)
        XCTAssertNil(model.exportTask); XCTAssertTrue(services.exportCalls.isEmpty)
    }

    func testEditThenUndoStillInvalidatesPanelAndFrameChangesAlsoInvalidate() async throws {
        let (model, services) = await ready()
        let token = try XCTUnwrap(model.prepareExport())
        model.adjust("brightness", to: 1)
        model.undo()
        model.startExport(destination: destination, token: token)
        XCTAssertNil(model.exportTask)
        let frameToken = try XCTUnwrap(model.prepareExport())
        model.frame.isEnabled.toggle()
        model.startExport(destination: destination, token: frameToken)
        XCTAssertNil(model.exportTask); XCTAssertTrue(services.exportCalls.isEmpty)
    }

    func testNewestTokenIsSingleUseAndBoundToItsIssuer() async throws {
        let (model, services) = await ready()
        let old = try XCTUnwrap(model.prepareExport())
        let current = try XCTUnwrap(model.prepareExport())
        model.startExport(destination: destination, token: old)
        XCTAssertNil(model.exportTask)
        let (other, otherServices) = await ready()
        other.startExport(destination: destination, token: current)
        XCTAssertNil(other.exportTask); XCTAssertTrue(otherServices.exportCalls.isEmpty)
        model.startExport(destination: destination, token: current)
        await eventually(timeout: .seconds(3)) { services.exportCalls.count == 1 }
        model.startExport(destination: destination, token: current)
        XCTAssertEqual(services.exportCalls.count, 1)
        model.cancelExport()
        await eventually(timeout: .seconds(3)) { !model.export.isInFlight }
    }
}
