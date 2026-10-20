import Foundation
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
        lut.spaceIssueKey = nil
    }

    /// The library's LUTs as the inspector offers them, in library order.
    var lutChoices: [LUTReference] { lut.library.compactMap { lutReferences[$0.id] } }

    /// Hands every library LUT the renderer does not have yet to it, so the
    /// inspector can choose any of them (the renderer finds a LUT by its
    /// content hash, p7-2b §3.1).
    func installLibraryLUTs() {
        let missing = lut.library.filter { lutReferences[$0.id] == nil }
        guard !missing.isEmpty else { return }
        lutInstallTask?.cancel()
        let editor = editor
        lutInstallTask = Task { [weak self, services] in
            for item in missing {
                guard !Task.isCancelled else { return }
                do {
                    let cube = try await services.lutCube(item.id)
                    let lut = try ColorLUT(cube: cube)
                    // The editor keeps it for exports too (`exportCapture`).
                    await editor.installLUT(lut)
                    self?.setLUTReference(LUTReference(contentHash: lut.contentHash, name: item.name), for: item.id)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.lut.failures = [UserFacingError(code: "lut_invalid", detail: item.name)]
                }
            }
            // A look waiting for its LUT can now be captured, and matched.
            self?.refreshExportMetadata()
        }
    }

    func importLUTs(_ urls: [URL]) async {
        guard editingLockReason == nil, !lut.isBusy else { return }
        invalidateLUTLibraryReads()
        lut.isBusy = true; lut.failures = []
        defer { lut.isBusy = false }
        for url in urls {
            guard !Task.isCancelled else { break }
            do { _ = try await services.importLUT(url) }
            catch {
                let failure = UserFacingError.service(error)
                lut.failures.append(UserFacingError(code: failure.code,
                    detail: url.lastPathComponent, variant: failure.variant))
            }
            invalidateLUTLibraryReads()
        }
        await refreshLUTLibrary()
    }
    func removeLUT(_ id: String) {
        guard !isEditingLocked else { return }
        invalidateLUTLibraryReads()
        Task { [weak self, services] in
            do { try await services.removeLUT(id) }
            catch { self?.lut.failures = [UserFacingError.service(error)] }
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
