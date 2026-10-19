import XCTest
#if M3_FRONTEND_INTEGRATION
import SwiftUI
#endif
@testable import HyperDR

@MainActor private final class LUTWriteGate {
    struct Request {
        let id: String
        let input: LUTColorSpace
        let output: LUTColorSpace
        let continuation: CheckedContinuation<LUTItem, any Error>
        func succeed() { continuation.resume(returning: LUTItem(id: id, name: id, input: input, output: output, byteCount: 42)) }
        func fail() { continuation.resume(throwing: UserFacingError(code: "lut_invalid")) }
    }
    var requests: [Request] = []
    func update(_ id: String, input: LUTColorSpace, output: LUTColorSpace) async throws -> LUTItem {
        try await withCheckedThrowingContinuation { requests.append(Request(id: id, input: input, output: output, continuation: $0)) }
    }
}

@MainActor final class LUTMetadataWriteTests: XCTestCase {
    private func fixture() -> (EditorModel, FakeEditorServices, LUTWriteGate) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero), gate = LUTWriteGate()
        services.updateLUTHandler = { try await gate.update($0, input: $1, output: $2) }
        let model = EditorModel(services: services)
        let entries = ["a", "b"].map { LUTItem(id: $0, name: $0, input: .srgb, output: .srgb, byteCount: 42) }
        services.library = entries; model.lut.library = entries
        return (model, services, gate)
    }

    func testRapidInputThenOutputKeepsBothDesiredChoicesAndRejectsOldReply() async {
        let (model, _, gate) = fixture()
        #if M3_FRONTEND_INTEGRATION
        // Run against the actual frontend popover when those commits are present.
        let inputs = spaceBindings(LUTSpacesPopover(model: model, id: "a").body)
        XCTAssertEqual(inputs.count, 2)
        guard inputs.count == 2 else { return }
        inputs[0].wrappedValue = .p3
        let outputs = spaceBindings(LUTSpacesPopover(model: model, id: "a").body)
        XCTAssertEqual(outputs.count, 2)
        guard outputs.count == 2 else { return }
        outputs[1].wrappedValue = .rec709
        #else
        model.setLibraryLUTSpaces("a", input: .p3, output: .srgb)
        XCTAssertEqual(model.lut.library[0].input, .p3)
        // The next popover render reads the real model's optimistic item.
        let next = model.lut.library[0]
        model.setLibraryLUTSpaces("a", input: next.input, output: .rec709)
        #endif
        XCTAssertEqual(model.lut.library[0].output, .rec709)
        await eventually(timeout: .seconds(3)) { gate.requests.count == 1 }
        XCTAssertEqual(gate.requests[0].input, .p3)
        gate.requests[0].succeed()
        await eventually(timeout: .seconds(3)) { gate.requests.count == 2 }
        XCTAssertEqual(model.lut.library[0].output, .rec709, "Old success must not replace the newer expected value")
        XCTAssertEqual(gate.requests[1].input, .p3); XCTAssertEqual(gate.requests[1].output, .rec709)
        gate.requests[1].succeed()
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.lut.library[0].input, .p3); XCTAssertEqual(model.lut.library[0].output, .rec709)
        XCTAssertEqual(model.lut.library[0].byteCount, 42)
        XCTAssertFalse(model.canUndo)
    }

    func testLastFailureRollsBackToMostRecentPersistedValueAndQueueContinues() async {
        let (model, _, gate) = fixture()
        model.setLibraryLUTSpaces("a", input: .p3, output: .srgb)
        model.setLibraryLUTSpaces("a", input: .p3, output: .rec709)
        await eventually(timeout: .seconds(3)) { gate.requests.count == 1 }
        gate.requests[0].succeed()
        await eventually(timeout: .seconds(3)) { gate.requests.count == 2 }
        gate.requests[1].fail()
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.lut.library[0].input, .p3); XCTAssertEqual(model.lut.library[0].output, .srgb)
        XCTAssertEqual(model.lut.failures.first?.code, "lut_invalid")
        model.setLibraryLUTSpaces("a", input: .rec709, output: .p3)
        await eventually(timeout: .seconds(3)) { gate.requests.count == 3 }
        gate.requests[2].succeed()
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.lut.library[0].input, .rec709); XCTAssertEqual(model.lut.library[0].output, .p3)
    }

    func testObsoleteFailureDoesNotRollBackNewerChoiceAndDifferentLUTsDoNotBlock() async {
        let (model, services, gate) = fixture()
        model.setLibraryLUTSpaces("a", input: .p3, output: .srgb)
        model.setLibraryLUTSpaces("a", input: .p3, output: .rec709)
        model.setLibraryLUTSpaces("b", input: .rec709, output: .p3)
        await eventually(timeout: .seconds(3)) { gate.requests.count == 2 }
        let firstA = gate.requests.first { $0.id == "a" }!, firstB = gate.requests.first { $0.id == "b" }!
        model.mergeLUTLibrary(services.library)
        XCTAssertEqual(model.lut.library[0].output, .rec709, "An async refresh cannot erase the pending choice")
        firstA.fail(); firstB.succeed()
        await eventually(timeout: .seconds(3)) { gate.requests.count == 3 }
        XCTAssertEqual(model.lut.library[0].input, .p3); XCTAssertEqual(model.lut.library[0].output, .rec709)
        gate.requests[2].succeed()
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.lut.library[1].input, .rec709); XCTAssertEqual(model.lut.library[1].output, .p3)
        XCTAssertEqual(model.lut.failures.first?.code, "lut_invalid")
        XCTAssertFalse(model.canUndo)
    }

    func testSelectedSpacesAreUndoableAndLibraryOnlyChangesAreNot() async {
        let (model, services, gate) = fixture()
        await model.loadExportServices()
        model.open([URL(fileURLWithPath: "/tmp/first.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        model.selectLUT("a")
        await eventually(timeout: .seconds(3)) { model.lut.selection?.id == "a" }
        model.clearUndo()
        model.setLibraryLUTSpaces("a", input: .p3, output: .rec709)
        XCTAssertEqual(model.lut.selection?.input, .p3); XCTAssertTrue(model.canUndo)
        await eventually(timeout: .seconds(3)) { gate.requests.count == 1 }
        model.undo()
        gate.requests[0].fail()
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.lut.selection?.input, .srgb)
        XCTAssertEqual(model.lut.library[0].input, .srgb)
        XCTAssertEqual(model.lut.failures.first?.code, "lut_invalid")
        model.selectLUT(nil); model.clearUndo()
        model.setLibraryLUTSpaces("b", input: .p3, output: .rec709)
        await eventually(timeout: .seconds(3)) { gate.requests.count == 2 }
        gate.requests[1].succeed()
        await model.lutMetadataTask?.value
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(services.library[0].input, .srgb)
    }

    func testSelectedFailureRollsBackMatchingPhotoSpaces() async {
        let (model, _, gate) = fixture()
        model.open([URL(fileURLWithPath: "/tmp/first.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        model.selectLUT("a")
        await eventually(timeout: .seconds(3)) { model.lut.selection?.id == "a" }
        model.setLibraryLUTSpaces("a", input: .p3, output: .rec709)
        await eventually(timeout: .seconds(3)) { gate.requests.count == 1 }
        gate.requests[0].fail()
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.lut.selection?.input, .srgb); XCTAssertEqual(model.lut.selection?.output, .srgb)
        XCTAssertEqual(model.lut.library[0].input, .srgb)
    }
}

#if M3_FRONTEND_INTEGRATION
@MainActor private func spaceBindings(_ value: Any) -> [Binding<LUTColorSpace>] {
    var result: [Binding<LUTColorSpace>] = []
    func walk(_ value: Any, _ depth: Int) {
        if let binding = value as? Binding<LUTColorSpace> { result.append(binding); return }
        guard depth < 35 else { return }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return }
        for child in mirror.children { walk(child.value, depth + 1) }
    }
    walk(value, 0)
    return result
}
#endif
