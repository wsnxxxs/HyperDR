import XCTest
import HyperDRRecipe
@testable import HyperDR

@MainActor final class LUTReadOrderingTests: XCTestCase {
    private func item(_ id: String, _ input: LUTColorSpace = .srgb, _ output: LUTColorSpace = .srgb) -> LUTItem {
        LUTItem(id: id, name: id, input: input, output: output)
    }
    func testOldPreImportListMustNotEraseANewLUTWithAPendingWrite() async {
        let services = FakeEditorServices(), model = EditorModel(services: services)
        let a = item("a"), b = item("b")
        services.library = [a]; model.lut.library = [a]
        var read: CheckedContinuation<[LUTItem], Never>?
        var calls = 0
        services.lutEntriesHandler = {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { read = $0 } }
            return services.library
        }
        let oldRefresh = Task { await model.refreshLUTLibrary() }
        await eventually(timeout: .seconds(3)) { read != nil }
        services.importedLUT = b
        await model.importLUTs([URL(fileURLWithPath: "/fixtures/b.cube")])
        XCTAssertNotNil(model.lut.library.first { $0.id == "b" })
        var write: CheckedContinuation<LUTItem, any Error>?
        services.updateLUTHandler = { _, _, _ in try await withCheckedThrowingContinuation { write = $0 } }
        model.setLibraryLUTSpaces("b", input: .p3, output: .rec709)
        await eventually(timeout: .seconds(3)) { write != nil }
        read?.resume(returning: [a]); read = nil
        await oldRefresh.value
        XCTAssertEqual(model.lut.library.first { $0.id == "b" }?.input, .p3)
        services.library = [a, item("b", .p3, .rec709)]
        write?.resume(returning: item("b", .p3, .rec709)); write = nil
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.lut.library.first { $0.id == "b" }?.output, .rec709)
    }

    func testWasWritingDoesNotStickAcrossLaterNormalRefreshes() async {
        let services = FakeEditorServices(), model = EditorModel(services: services)
        services.library = [item("a")]; model.lut.library = services.library
        model.setLibraryLUTSpaces("a", input: .p3, output: .rec709)
        await model.lutMetadataTask?.value
        for index in 0..<8 {
            let input: LUTColorSpace = index.isMultiple(of: 2) ? .rec709 : .srgb
            services.library = [item("a", input, .p3)]
            await model.refreshLUTLibrary()
            XCTAssertEqual(model.lut.library, services.library)
            XCTAssertEqual(model.lutLibraryReadVersions()["a"]?.wasWriting, false)
        }
        services.library = []
        await model.refreshLUTLibrary()
        XCTAssertTrue(model.lut.library.isEmpty, "A later authoritative list may remove an unprotected id")
    }

    func testCancelledRefreshNeverMergesEvenWhenTheServiceIgnoresCancellation() async {
        let services = FakeEditorServices(), model = EditorModel(services: services)
        let old = item("a"); model.lut.library = [old]
        var read: CheckedContinuation<[LUTItem], Never>?
        services.lutEntriesHandler = { await withCheckedContinuation { read = $0 } }
        let refresh = Task { await model.refreshLUTLibrary() }
        await eventually(timeout: .seconds(3)) { read != nil }
        refresh.cancel(); model.lut.library = [item("a", .p3, .rec709)]
        read?.resume(returning: [old]); read = nil
        await refresh.value
        XCTAssertEqual(model.lut.library.first?.input, .p3)
        XCTAssertEqual(model.lut.library.first?.output, .rec709)
    }

    func testOlderWholeListIsDiscardedAfterNewerRefreshCommits() async {
        let services = FakeEditorServices(), model = EditorModel(services: services)
        let a = item("a"), b = item("b")
        model.lut.library = [a]
        var read: CheckedContinuation<[LUTItem], Never>?
        var calls = 0
        services.lutEntriesHandler = {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { read = $0 } }
            return [a, b]
        }
        let old = Task { await model.refreshLUTLibrary() }
        await eventually(timeout: .seconds(3)) { read != nil }
        await model.refreshLUTLibrary()
        XCTAssertEqual(model.lut.library, [a, b])
        read?.resume(returning: [a]); read = nil
        await old.value
        XCTAssertEqual(model.lut.library, [a, b])
    }

    func testOldListCannotReviveADeletedID() async {
        let services = FakeEditorServices(), model = EditorModel(services: services)
        let old = [item("a"), item("b")]
        services.library = old; model.lut.library = old
        var read: CheckedContinuation<[LUTItem], Never>?
        var calls = 0
        services.lutEntriesHandler = {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { read = $0 } }
            return services.library
        }
        let refresh = Task { await model.refreshLUTLibrary() }
        await eventually(timeout: .seconds(3)) { read != nil }
        model.removeLUT("b")
        await eventually(timeout: .seconds(3)) { model.lut.library.map(\.id) == ["a"] && services.library.map(\.id) == ["a"] }
        read?.resume(returning: old); read = nil
        await refresh.value
        XCTAssertEqual(model.lut.library, services.library)
        XCTAssertEqual(model.lut.library.map(\.id), ["a"])
    }

    func testInterleavedImportAndDeleteEndWithTheDiskMembership() async {
        let services = FakeEditorServices(), model = EditorModel(services: services)
        let old = [item("a"), item("b")]
        services.library = old; model.lut.library = old
        var read: CheckedContinuation<[LUTItem], Never>?
        var remove: CheckedContinuation<Void, Never>?
        var calls = 0
        services.lutEntriesHandler = {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { read = $0 } }
            return services.library
        }
        services.removeLUTHandler = { id in
            await withCheckedContinuation { remove = $0 }
            services.library.removeAll { $0.id == id }
        }
        let refresh = Task { await model.refreshLUTLibrary() }
        await eventually(timeout: .seconds(3)) { read != nil }
        model.removeLUT("b")
        await eventually(timeout: .seconds(3)) { remove != nil }
        services.importedLUT = item("c")
        await model.importLUTs([URL(fileURLWithPath: "/fixtures/c.cube")])
        XCTAssertEqual(model.lut.library.map(\.id), ["a", "b", "c"])
        remove?.resume(); remove = nil
        await eventually(timeout: .seconds(3)) { model.lut.library.map(\.id) == ["a", "c"] }
        read?.resume(returning: old); read = nil
        await refresh.value
        XCTAssertEqual(model.lut.library, services.library)
        XCTAssertEqual(model.lut.library.map(\.id), ["a", "c"])
    }

    func testSuccessForMissingIndexReconcilesDiskWithoutResurrectingDeletedID() async {
        for deleted in [false, true] {
            let services = FakeEditorServices(), model = EditorModel(services: services)
            let a = item("a")
            services.library = [a]; model.lut.library = [a]
            var write: CheckedContinuation<LUTItem, any Error>?
            services.updateLUTHandler = { _, _, _ in try await withCheckedThrowingContinuation { write = $0 } }
            model.setLibraryLUTSpaces("a", input: .p3, output: .rec709)
            await eventually(timeout: .seconds(3)) { write != nil }
            var reads = 0
            services.lutEntriesHandler = {
                reads += 1
                return reads == 1 ? [] : services.library
            }
            await model.refreshLUTLibrary()
            XCTAssertTrue(model.lut.library.isEmpty)
            services.library = deleted ? [] : [item("a", .p3, .rec709)]
            write?.resume(returning: item("a", .p3, .rec709)); write = nil
            await model.lutMetadataTask?.value
            XCTAssertEqual(reads, 2, "A missing index success must explicitly reconcile membership")
            XCTAssertEqual(model.lut.library, services.library)
        }
    }
}

@MainActor final class LUTLifecycleTests: XCTestCase {
    private func ready() async throws -> (EditorModel, FakeEditorServices) {
        let services = FakeEditorServices(openDelay: .zero)
        services.library = [LUTItem(id: "a", name: "Film", input: .srgb, output: .srgb)]
        let model = EditorModel(services: services)
        await model.loadExportServices()
        model.open([URL(fileURLWithPath: "/tmp/lut-lifecycle.jpg")])
        await eventually(timeout: .seconds(5)) { model.document?.phase == .ready }
        await model.chooseLibraryLUT("a")
        XCTAssertNotNil(model.editor.recipe.look)
        return (model, services)
    }

    func testLibrarySpaceUndoRedoRestoresPersistedSpaces() async throws {
        let (model, services) = try await ready()
        defer { model.closeDocument() }
        model.setLibraryLUTSpaces("a", input: .rec709, output: .p3)
        await model.lutMetadataTask?.value
        XCTAssertEqual(services.library[0].input, .rec709)
        model.undo()
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.editor.recipe.conditionValue("look.input")?.stringValue, "srgb")
        XCTAssertEqual(model.lut.library[0].input, .srgb)
        XCTAssertEqual(services.library[0].input, .srgb)
        XCTAssertEqual(services.library[0].output, .srgb)
        model.redo()
        await model.lutMetadataTask?.value
        XCTAssertEqual(model.editor.recipe.conditionValue("look.output")?.stringValue, "p3")
        XCTAssertEqual(services.library[0].input, .rec709)
        XCTAssertEqual(services.library[0].output, .p3)
    }

    func testFailedRemovalKeepsTheLookAndSuccessfulRemovalIsUndoable() async throws {
        let (model, services) = try await ready()
        defer { model.closeDocument() }
        let before = model.editor.recipe
        var deletion: CheckedContinuation<Void, any Error>?
        services.removeLUTHandler = { _ in
            try await withCheckedThrowingContinuation { deletion = $0 }
        }
        model.removeLUT("a")
        await eventually(timeout: .seconds(3)) { deletion != nil }
        XCTAssertEqual(model.editor.recipe, before, "Keep the photo while deletion is pending")
        deletion?.resume(throwing: UserFacingError(code: "lut_invalid")); deletion = nil
        await eventually(timeout: .seconds(3)) { !model.lut.failures.isEmpty }
        XCTAssertEqual(model.editor.recipe, before)
        XCTAssertEqual(model.lut.library.count, 1)
        services.removeLUTHandler = nil
        model.removeLUT("a")
        await eventually(timeout: .seconds(3)) { model.lut.library.isEmpty }
        XCTAssertNil(model.editor.recipe.look)
        model.undo()
        XCTAssertEqual(model.editor.recipe, before)
        XCTAssertTrue(model.lut.library.isEmpty, "Undo restores the photo, not a deleted library file")
    }

    func testRemovalWaitsForPendingSpaceWrite() async throws {
        let (model, services) = try await ready()
        defer { model.closeDocument() }
        var write: CheckedContinuation<LUTItem, any Error>?
        services.updateLUTHandler = { _, _, _ in
            try await withCheckedThrowingContinuation { write = $0 }
        }
        model.setLibraryLUTSpaces("a", input: .p3, output: .rec709)
        await eventually(timeout: .seconds(3)) { write != nil }
        model.removeLUT("a")
        await Task.yield()
        XCTAssertEqual(services.library.count, 1)
        write?.resume(returning: LUTItem(id: "a", name: "Film", input: .p3, output: .rec709)); write = nil
        await eventually(timeout: .seconds(3)) { model.lut.library.isEmpty }
        XCTAssertTrue(services.library.isEmpty)
        XCTAssertNil(model.editor.recipe.look)
    }
}

extension LUTLifecycleTests {
    func testImportFinishingAfterAPhotoSwitchDoesNotApplyToTheNewPhoto() async throws {
        let (model, services) = try await ready()
        defer { model.closeDocument() }
        services.importedLUT = LUTItem(id: "b", name: "New", input: .rec709, output: .rec709)
        var read: CheckedContinuation<[LUTItem], Never>?
        var calls = 0
        services.lutEntriesHandler = {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { read = $0 } }
            return services.library
        }
        let importing = Task { await model.importLUTs([URL(fileURLWithPath: "/tmp/new.cube")]) }
        await eventually(timeout: .seconds(3)) { read != nil }
        let second = URL(fileURLWithPath: "/tmp/lut-second.jpg")
        model.open([second])
        await eventually(timeout: .seconds(5)) { model.photo?.url == second && model.document?.phase == .ready }
        read?.resume(returning: services.library); read = nil
        await importing.value
        XCTAssertNil(model.editor.recipe.look)
        XCTAssertTrue(services.library.contains { $0.id == "b" }, "The import is still kept in the library")
    }
}

extension LUTLifecycleTests {
    func testFailedSpaceWriteRestoresBothThePhotoAndLibraryWithoutAnotherWrite() async throws {
        let (model, services) = try await ready()
        defer { model.closeDocument() }
        var writes = 0
        services.updateLUTHandler = { _, _, _ in
            writes += 1
            throw UserFacingError(code: "lut_invalid")
        }
        model.setLibraryLUTSpaces("a", input: .p3, output: .rec709)
        await model.lutMetadataTask?.value
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.lut.library[0].input, .srgb)
        XCTAssertEqual(model.editor.recipe.conditionValue("look.input")?.stringValue, "srgb")
        XCTAssertEqual(model.editor.recipe.conditionValue("look.output")?.stringValue, "srgb")
        XCTAssertFalse(model.lut.failures.isEmpty)
    }
}
