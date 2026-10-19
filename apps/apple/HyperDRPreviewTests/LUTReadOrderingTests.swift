import XCTest
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
