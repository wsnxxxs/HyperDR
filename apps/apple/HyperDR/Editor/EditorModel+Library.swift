import Foundation
import HyperDRDesign
import HyperDRKit
import HyperDREngine
import HyperDRRecipe
import HyperDRRender

extension EditorModel {
    /// What the export summary says about the look: the recipe's LUT, by name.
    func syncLUTState() {
        guard let look = editor.recipe.look else {
            if lut.selection != nil { lut.selection = nil }
            return
        }
        // The library entry whose contents the look names; a look whose LUT
        // is not in the library is shown by its name.
        let id = lutReferences.first { $0.value.contentHash == look.contentHash }?.key
        let item = lut.library.first { $0.id == id }
            ?? LUTItem(id: look.contentHash, name: look.name, input: .srgb, output: .srgb)
        if lut.selection != item { lut.selection = item }
        lut.isEnabled = editor.recipe.conditionValue("look.enabled")?.boolValue ?? true
    }

    /// The library's LUTs with their spaces, for `lookPreviews`.
    var lookPreviewLooks: [LookPreviews.Look] {
        lut.library.compactMap { item in
            lutReferences[item.id].map { LookPreviews.Look(reference: $0, input: item.input.rawValue, output: item.output.rawValue) }
        }
    }

    /// Records the spaces a control chose on the look (`Recipe.chosenLookSpaces`)
    /// for its LUT, so the next choice of it starts from them.
    func recordLookSpaces(from old: Recipe, to new: Recipe) {
        guard let chosen = Recipe.chosenLookSpaces(from: old, to: new),
              let id = lutReferences.first(where: { $0.value.contentHash == chosen.contentHash })?.key,
              let item = lut.library.first(where: { $0.id == id }) else { return }
        enqueueLUTSpaces(id, input: chosen.input.flatMap(LUTColorSpace.init(rawValue:)) ?? item.input,
                         output: chosen.output.flatMap(LUTColorSpace.init(rawValue:)) ?? item.output)
    }

    /// The library's LUTs as the inspector offers them, in library order.
    var lutChoices: [LUTReference] { lut.library.compactMap { lutReferences[$0.id] } }

    /// The spaces the library records for each LUT, by content hash: choosing
    /// a LUT in the inspector starts the look's spaces from them.
    var lutSpaces: [String: AdjustmentLookSpaces] {
        Dictionary(lut.library.compactMap { item in
            lutReferences[item.id].map { ($0.contentHash, AdjustmentLookSpaces(input: item.input.rawValue, output: item.output.rawValue)) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Hands every library LUT the renderer does not have yet to it, so the
    /// inspector can choose any of them (the renderer finds a LUT by its
    /// content hash, p7-2b §3.1).
    func installLibraryLUTs() {
        let missing = lut.library.filter { lutReferences[$0.id] == nil }
        guard !missing.isEmpty else { return }
        lutInstallTask?.cancel()
        let editor = editor
        lutInstallTask = Task { [weak self, services] in
            let failures = await editor.installLibraryLUTs(missing.map { LibraryLUT(id: $0.id, name: $0.name) },
                                                           cube: { try await services.lutCube($0) }) { id, reference in
                self?.setLUTReference(reference, for: id)
            }
            guard !Task.isCancelled else { return }
            if let name = failures.last { self?.lut.failures = [UserFacingError(code: "lut_invalid", detail: name)] }
            // A look waiting for its LUT can now be captured, and matched.
            self?.refreshExportMetadata()
        }
    }

    /// Imports `.cube` files. One file imported with a photo open becomes its
    /// look: a LUT is imported to be used.
    func importLUTs(_ urls: [URL]) async {
        guard editingLockReason == nil, !lut.isBusy else { return }
        invalidateLUTLibraryReads()
        lut.isBusy = true; lut.failures = []
        defer { lut.isBusy = false }
        let sourceID = editor.source?.id
        var imported: [String] = []
        for url in urls {
            guard !Task.isCancelled else { break }
            do { imported.append(try await services.importLUT(url).id) }
            catch {
                let failure = UserFacingError.service(error)
                lut.failures.append(UserFacingError(code: failure.code,
                    detail: url.lastPathComponent, variant: failure.variant))
            }
            invalidateLUTLibraryReads()
        }
        await refreshLUTLibrary()
        if !Task.isCancelled, !isEditingLocked, let sourceID, editor.source?.id == sourceID,
           urls.count == 1, let id = imported.first { await chooseLibraryLUT(id) }
    }

    /// Makes a library LUT the photo's look, with its spaces, once the
    /// renderer has it.
    func chooseLibraryLUT(_ id: String) async {
        let sourceID = editor.source?.id
        await lutInstallTask?.value
        guard !Task.isCancelled, !isEditingLocked, let sourceID, editor.source?.id == sourceID else { return }
        guard let item = lut.library.first(where: { $0.id == id }), let reference = lutReferences[id] else { return }
        editor.chooseLook(reference, input: item.input.rawValue, output: item.output.rawValue)
    }

    /// Removes a LUT from the library, and the open photo's look when it is
    /// on that LUT (one undo step).
    func removeLUT(_ id: String) {
        guard !isEditingLocked else { return }
        let reference = lutReferences[id]
        let pendingWrite = lutMetadataWrites[id]?.task
        invalidateLUTLibraryReads()
        Task { [weak self, services] in
            await pendingWrite?.value
            do {
                try await services.removeLUT(id)
                if let reference { self?.editor.dropLook(reference.contentHash) }
            } catch { self?.lut.failures = [UserFacingError.service(error)] }
            guard let self else { return }
            // Fence reads begun during a mutation too, including partial failure.
            invalidateLUTLibraryReads()
            await refreshLUTLibrary()
        }
    }
    func updatePreferences(_ value: Preferences) {
        value.save(to: services.preferences)
        preferences.value = Preferences.load(from: services.preferences)
        showsHighlightZebra = preferences.value.highlightZebra
        showsShadowZebra = preferences.value.shadowZebra
        syncExportState()
    }
    func resetPreferences() { updatePreferences(Preferences()) }
    func revealExportFolder() async {
        guard preferences.exportFolder.ready, let target = preferences.exportFolder.target else { return }
        do { try await target.reveal(); preferences.failure = nil }
        catch { preferences.failure = UserFacingError.service(error) }
    }
    var aboutInformation: AboutInformation {
        var information = preferences.about
        information.osBuild = document?.source?.raw?.osBuild
        information.decoderVersion = document?.source?.raw?.decoderVersion
        return information
    }
    func setExportFolder(_ url: URL) async {
        do { preferences.exportFolder = try await services.setExportFolder(url); preferences.failure = nil }
        catch { preferences.failure = UserFacingError.service(error) }
        syncExportState()
    }
    func rememberOutputPreferences() {
        guard preferences.value.rememberOutput else { return }
        let output = ["encoding": exportChoices.encoding, "outputGamut": exportChoices.outputGamut]
        preferences.value.output = output
        preferences.value.save(to: services.preferences)
    }
    /// The remembered export choices and view preferences, with no undo entry.
    func applyInitialPreferences() {
        let p = preferences.value
        if p.rememberOutput {
            if let v = p.output["outputGamut"] { exportChoices.outputGamut = v }
        }
        showsHighlightZebra = p.highlightZebra; showsShadowZebra = p.shadowZebra
        viewMode = p.initialView == .original ? .original : .edited
        syncControls()
    }
}
