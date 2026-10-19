import Foundation
import HyperDRKit
import HyperDREngine

extension EditorModel {
    func syncLUTState() {
        lut.selection = edit.lutID.isEmpty ? nil : LUTItem(id: edit.lutID, name: edit.lutName,
            input: LUTColorSpace(rawValue: edit.choices["lutInput"] ?? "srgb") ?? .srgb,
            output: LUTColorSpace(rawValue: edit.choices["lutOutput"] ?? "srgb") ?? .srgb)
        lut.isEnabled = edit.lutEnabled
        let issue = LUTCompatibility.issue(input: LUTSpace(rawValue: edit.choices["lutInput"] ?? "srgb") ?? .srgb,
            output: LUTSpace(rawValue: edit.choices["lutOutput"] ?? "srgb") ?? .srgb, isRAW: photo?.formatLabel == "RAW")
        let reason: String?
        switch issue {
        case .sdrOutput: reason = "lut.spaceIssue.sdrOutput"
        case .sceneInput: reason = "lut.spaceIssue.sceneInput"
        case .logOutput: reason = "lut.spaceIssue.logOutput"
        case nil: reason = nil
        }
        lut.spaceIssueKey = edit.lutID.isEmpty ? nil : reason
    }
    func selectLUT(_ id: String?) {
        guard photo != nil, !isEditingLocked else { return }
        finishGestureBeforeEdit()
        lutTicket += 1; let ticket = lutTicket
        lutTask?.cancel()
        guard let id else {
            lut.isBusy = false
            let previous = edit; edit.lutID = ""; edit.lutName = ""
            recordStep(from: previous, action: "lut"); editChanged(); return
        }
        guard let photo else { return }
        lut.isBusy = true
        lutTask = Task { [weak self, services] in
            defer { if let self, lutTicket == ticket { lut.isBusy = false } }
            do {
                let entry = try await services.applyLUT(id, to: photo)
                guard let self, !Task.isCancelled, self.photo == photo, lutTicket == ticket, !isEditingLocked else { return }
                let previous = edit
                edit.lutID = entry.id; edit.lutName = entry.name; edit.lutEnabled = true
                edit.choices["lutInput"] = entry.input.rawValue; edit.choices["lutOutput"] = entry.output.rawValue
                recordStep(from: previous, action: "lut"); editChanged()
            } catch {
                if let self, lutTicket == ticket, !Task.isCancelled { lut.failures = [UserFacingError.service(error)] }
            }
        }
    }
    func setLUTEnabled(_ on: Bool) {
        guard photo != nil, !isEditingLocked, edit.lutEnabled != on else { return }
        finishGestureBeforeEdit()
        let previous = edit; edit.lutEnabled = on
        recordStep(from: previous, action: "lut"); editChanged()
    }
    func setLUTInput(_ input: LUTColorSpace) {
        let output = input == .slog3SGamut3Cine ? LUTColorSpace.rec709 : (lut.selection?.output ?? .srgb)
        setLUTSpaces(input: input, output: output)
    }
    func setLUTSpaces(input: LUTColorSpace, output: LUTColorSpace) {
        guard photo != nil, !isEditingLocked, !edit.lutID.isEmpty else { return }
        finishGestureBeforeEdit()
        let previous = edit
        edit.choices["lutInput"] = input.rawValue; edit.choices["lutOutput"] = output.rawValue
        recordStep(from: previous, action: "lut"); editChanged()
        enqueueLUTSpaces(edit.lutID, input: input, output: output, selectedPhoto: photo)
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
    /// Invalid spaces keep the selected LUT and strength in undo, but the
    /// request carries zero strength. Kit owns the sole constraint function.
    func effectiveOptions() -> EditOptions {
        var options = edit.options()
        if !edit.lutID.isEmpty, LUTCompatibility.issue(
            input: LUTSpace(rawValue: edit.choices["lutInput"] ?? "srgb") ?? .srgb,
            output: LUTSpace(rawValue: edit.choices["lutOutput"] ?? "srgb") ?? .srgb,
            isRAW: photo?.formatLabel == "RAW") != nil { options["lutStrength"] = .number(0); options["lutId"] = .string("") }
        return options
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
        var output = ["encoding": edit.encoding, "colorGamut": edit.choices["colorGamut"] ?? "srgb",
            "outputGamut": edit.choices["outputGamut"] ?? "auto", "clampSrgb": edit.clampSrgb ? "true" : "false"]
        if !edit.selectedModel.isEmpty { output["modelId"] = edit.selectedModel }
        preferences.value.output = output
        preferences.value.save(to: services.preferences)
    }
    /// Initial preview may already be on screen; differences are submitted
    /// through the normal coalescer, with no undo entry or restored adjustments.
    func applyInitialPreferences() {
        let p = preferences.value
        if p.rememberOutput {
            for key in ["colorGamut", "outputGamut"] { if let v = p.output[key] { edit.choices[key] = v } }
            if let v = p.output["clampSrgb"] { edit.clampSrgb = v == "true" }
            if let v = p.output["modelId"], photoModels().contains(where: { $0.id == v && $0.isEnabled }) { edit.selectedModel = v }
        }
        showsHighlightZebra = p.highlightZebra; showsShadowZebra = p.shadowZebra
        viewMode = p.initialView == .original ? .original : .edited
        syncControls(); scheduleRender()
    }
}
