import Foundation
import AppKit
import HyperDRKit
import HyperDREngine

/// What the open photo told the model about itself.
struct PhotoSource: Equatable {
    var domain: InputDomain?
    /// An HDR source's own control values (its identity rendering).
    var unadjusted: [String: Double]?
    var colorSource: String?
    var hasCaptureMetadata = false
}

/// What colour-only mode remembers to restore on the way back to HDR.
struct RememberedHDR: Equatable {
    var encoding: String?
    var aiMode: AIMode = .manual
}

/// One render the scheduler may submit: the request, and whether it is a
/// draft (the smaller edge used while a control is dragged).
struct RenderJob: Equatable {
    let options: EditOptions
    let draft: Bool
    var trace: PreviewTrace? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.options == rhs.options && lhs.draft == rhs.draft }
}

extension EditorModel {
    /// The draft long edge while dragging (batch3 §3.4; A3 may change it).
    static let draftEdge = 640

    // MARK: - Lock

    /// One switch for everything that must not change the photo: before the
    /// first frame, while opening or restoring, while AI computes (batch4
    /// §2.12). Control enablement, undo, the processing mode and open derive
    /// from it; views never combine their own conditions.
    var editingLockReason: EditingLockReason? {
        if export.isInFlight { return .exporting }
        if isRestoring { return .restoring }
        guard document != nil else { return nil }
        if !hasEditedFrame || document?.phase != .ready || photo == nil { return .loading }
        return ai.isComputing ? .computingAI : nil
    }
    var isEditingLocked: Bool { editingLockReason != nil }

    var canSetWorkflow: Bool { photo != nil && !isEditingLocked }
    /// User commands stay enabled in an empty workspace and for replacing
    /// a ready/failed photo. Finder/drop/programmatic open can supersede an
    /// in-progress open (Q14); AI computation blocks both entry points.
    var photoSwitch: PhotoSwitchPolicy {
        if export.isInFlight { return .confirmStoppingExport }
        if isRestoring { return .unavailable(reasonKey: "export.blocker.restoring") }
        if ai.isComputing { return .unavailable(reasonKey: "export.blocker.ai") }
        if document?.phase == .opening || document?.phase == .rendering { return .unavailable(reasonKey: "export.blocker.loading") }
        return .allowed
    }
    var canOpenDocument: Bool {
        if case .unavailable = photoSwitch { return false }; return true
    }

    var canResetAll: Bool { photo != nil && !isEditingLocked }

    // MARK: - Controls

    /// The same object for a key while the model lives.
    func control(_ key: String) -> ControlValue {
        if let value = controlValues[key] { return value }
        preconditionFailure("Unknown control \(key)")
    }

    var controls: [ControlValue] { EditControls.all.compactMap { controlValues[$0.key] } }

    /// Sets a value: clamped to the effective range, then rounded to what the
    /// readout shows (batch4 §2.2). Outside a drag every call is one undo
    /// step; inside one, `endAdjusting` records the whole drag.
    func adjust(_ key: String, to value: Double) {
        guard photo != nil, value.isFinite, !isEditingLocked, let control = controlValues[key] else { return }
        if let gesture, gesture.key != key { endAdjusting(gesture.key) }
        let next: Double
        if control.spec.allowsAuto && value < 0 {
            next = -1
        } else {
            let range = control.range
            next = min(range.upperBound, max(range.lowerBound, control.spec.format.quantize(
                min(range.upperBound, max(range.lowerBound, value)))))
        }
        guard edit.controls[key] != next else { return }
        invalidateDetails(editedOnly: true)
        let previous = edit
        edit.controls[key] = next
        control.update(value: next)
        if let gesture, gesture.key == key {
            scheduleRender(draft: true)
        } else {
            recordStep(from: previous, action: key)
            scheduleRender()
        }
    }

    func beginAdjusting(_ key: String) {
        guard photo != nil, !isEditingLocked, controlValues[key] != nil else { return }
        if let gesture, gesture.key != key { endAdjusting(gesture.key) }
        if gesture == nil { gesture = (key, edit) }
    }

    func endAdjusting(_ key: String) {
        guard let started = gesture, started.key == key else { return }
        gesture = nil
        if let control = controlValues[key], let value = edit.controls[key],
           !(control.spec.allowsAuto && value < 0) {
            let range = ControlRules.range(control.spec, encoding: edit.encoding, domain: source.domain)
            edit.controls[key] = min(range.upperBound, max(range.lowerBound, value))
        }
        recordStep(from: started.start, action: key)
        syncControls()
        // Replace the draft frame with a full one.
        if lastJob?.draft == true { scheduleRender() }
    }

    /// Double-click: back to this photo's default for the current format.
    func resetControl(_ key: String) {
        guard let value = defaultsForCurrentEncoding().controls[key] else { return }
        guard photo != nil, !isEditingLocked else { return }
        finishGestureBeforeEdit()
        guard edit.controls[key] != value else { return }
        let previous = edit
        edit.controls[key] = value
        invalidateDetails(editedOnly: true)
        syncControls()
        recordStep(from: previous, action: key)
        scheduleRender()
    }

    /// Auto-capable controls only; writes −1.
    func setAuto(_ key: String) {
        guard photo != nil, !isEditingLocked, controlValues[key]?.spec.allowsAuto == true else { return }
        finishGestureBeforeEdit()
        adjust(key, to: -1)
    }

    /// Back to how this photo opened, for the current output format: AI back
    /// to manual (its gain stays cached), the encoding and mode unchanged.
    func resetAll() {
        guard photo != nil, !isEditingLocked else { return }
        finishGestureBeforeEdit()
        var target = defaultsForCurrentEncoding()
        target.selectedModel = edit.selectedModel
        target.aiMode = .manual
        let previous = edit
        notice = .resetDone
        guard target != edit else { return }
        edit = target
        recordStep(from: previous, action: "reset")
        editChanged()
    }

    func defaultsForCurrentEncoding() -> EditSnapshot {
        EditSnapshot(EditBaseline.initial(encoding: edit.encoding, domain: source.domain,
                                          unadjusted: source.unadjusted))
    }

    // MARK: - Processing mode, format, input colour

    /// One undo step. Colour-only remembers the HDR encoding and AI mode and
    /// restores both on the way back (AI only while it can run).
    func setWorkflow(_ workflow: Workflow) {
        guard photo != nil, !isEditingLocked, workflow != edit.workflow else { return }
        switch workflow {
        case .colorOnly: changeEncoding(to: "sdr-jpeg", action: "workflow")
        case .hdr: changeEncoding(to: remembered.encoding ?? "adaptive", action: "workflow")
        }
    }

    /// The output format. M2's interface only switches it through the
    /// processing mode; the export interface (M3) uses this directly.
    func selectEncoding(_ id: String) {
        guard photo != nil, !isEditingLocked, (export.encodingAvailability[id] ?? nil) == nil, id != edit.encoding,
              EditChoices.byKey["encoding"]?.options.contains(where: { $0.id == id }) == true else { return }
        changeEncoding(to: id, action: "encoding")
    }

    private func changeEncoding(to id: String, action: String) {
        finishGestureBeforeEdit()
        let previous = edit
        let from = Workflow(encoding: previous.encoding), to = Workflow(encoding: id)
        edit.choices["encoding"] = id
        if from == .hdr && to == .colorOnly {
            remembered = RememberedHDR(encoding: previous.encoding, aiMode: previous.aiMode)
            edit.aiMode = .manual
        } else if from == .colorOnly && to == .hdr {
            let canRun = aiBlockReason(workflow: .hdr) == nil && aiFailureReason == nil
            edit.aiMode = canRun ? remembered.aiMode : .manual
        }
        clampForEncoding(from: previous.encoding)
        if (edit.controls["hdrRange"] ?? 0) < (previous.controls["hdrRange"] ?? 0) { notice = .rangeClamped(maxStops: EditBaseline.maxRange(for: id)) }
        recordStep(from: previous, action: action)
        editChanged()
    }

    /// The HDR range ceilings follow the format. The value of a control being
    /// dragged is left alone; `endAdjusting` corrects it.
    private func clampForEncoding(from old: String) {
        let new = edit.encoding
        for key in ["hdrRange", "aiHdrRange"] where gesture?.key != key {
            guard let control = controlValues[key], var value = edit.controls[key] else { continue }
            let range = ControlRules.range(control.spec, encoding: new, domain: source.domain)
            if key == "hdrRange", let identity = hdrIdentityRange(at: old), value == identity,
               let restored = hdrIdentityRange(at: new) {
                // An HDR source still at its own rendering follows the
                // format's ceiling both ways (Web `controls.js`).
                value = restored
            }
            if !(control.spec.allowsAuto && value < 0) {
                value = min(range.upperBound, max(range.lowerBound, value))
            }
            edit.controls[key] = value
        }
    }

    /// An HDR source's own range at this encoding, while brightness and
    /// strength are still the source's own; nil otherwise.
    private func hdrIdentityRange(at encoding: String) -> Double? {
        guard source.domain == .hdr || source.domain == .dual,
              let unadjusted = source.unadjusted, let range = unadjusted["hdrRange"],
              edit.controls["brightness"] == unadjusted["brightness"],
              edit.controls["hdrStrength"] == unadjusted["hdrStrength"] else { return nil }
        return min(range, EditBaseline.maxRange(for: encoding))
    }

    /// Untagged RGB only (`colorSource == "assumed"`); RAW hides it.
    func selectInputColor(_ id: String) {
        guard photo != nil, !isEditingLocked, inputColor.isEnabled, id != edit.choices["colorGamut"],
              inputColor.choices.contains(where: { $0.id == id }) else { return }
        finishGestureBeforeEdit()
        let previous = edit
        edit.choices["colorGamut"] = id
        aiFailureReason = nil
        recordStep(from: previous, action: "inputColor")
        editChanged()
    }

    // MARK: - Undo (batch4 §2.4)

    /// Compatibility boundary for the window's environment manager. The
    /// editor owns a separate explicit-group history; NEVER change the shared
    /// window manager (NSTextView relies on its automatic event grouping).
    /// Detaching clears only editor history.
    func attach(undoManager windowManager: UndoManager?) {
        if windowManager == nil { clearUndo() }
    }

    /// Commands route field editors and text views to AppKit's own history.
    /// Other responders use the editor history and its lock conditions.
    static func routesUndoToText(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    func canUndo(firstResponder: NSResponder?) -> Bool {
        Self.routesUndoToText(firstResponder) ? firstResponder?.undoManager?.canUndo == true : canUndo
    }

    func canRedo(firstResponder: NSResponder?) -> Bool {
        Self.routesUndoToText(firstResponder) ? firstResponder?.undoManager?.canRedo == true : canRedo
    }

    func undo(firstResponder: NSResponder?) {
        if Self.routesUndoToText(firstResponder) { firstResponder?.undoManager?.undo() }
        else { undo() }
    }

    func redo(firstResponder: NSResponder?) {
        if Self.routesUndoToText(firstResponder) { firstResponder?.undoManager?.redo() }
        else { redo() }
    }

    var canUndo: Bool {
        _ = undoRevision
        return !isEditingLocked && gesture == nil && undoManager.canUndo == true
    }

    var canRedo: Bool {
        _ = undoRevision
        return !isEditingLocked && gesture == nil && undoManager.canRedo == true
    }

    func undo() {
        guard canUndo else { return }
        undoManager.undo()
        bumpUndoRevision()
    }

    func redo() {
        guard canRedo else { return }
        undoManager.redo()
        bumpUndoRevision()
    }

    /// One step back to `previous`, unless nothing changed. The menu title is
    /// the localized `undo.<action>`.
    func recordStep(from previous: EditSnapshot, action: String) {
        guard previous != edit else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreStep(previous, action: action) }
        }
        undoManager.setActionName(Self.undoActionName(action))
        undoManager.endUndoGrouping()
        bumpUndoRevision()
    }

    /// Undo / redo: restores the values and registers the way back.
    private func restoreStep(_ snapshot: EditSnapshot, action: String) {
        let current = edit
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreStep(current, action: action) }
        }
        undoManager.setActionName(Self.undoActionName(action))
        gesture = nil
        edit = snapshot
        editChanged()
        bumpUndoRevision()
    }

    func clearUndo() {
        undoManager.removeAllActions(withTarget: self)
        gesture = nil
        bumpUndoRevision()
    }

    func endGesture() { gesture = nil }

    /// Every discrete edit first commits the active drag/repeat. Its undo
    /// step therefore cannot absorb a format, mode, reset or model change.
    func finishGestureBeforeEdit() {
        if let gesture { endAdjusting(gesture.key) }
    }

    // MARK: - Photo lifetime

    /// The opened photo's values: `EditDefaults.initial` for the run's
    /// encoding and this reference frame, AI manual, view state reset.
    func beginEditing(encoding: String, reference: EditorPreview) {
        referenceRefreshTask?.cancel()
        invalidateDetails()
        hideMask()
        lastSubmitWasDraft = false
        referenceOptions = EditDefaults.reference(encoding: encoding,
            workflow: EditDefaults.initial(encoding: encoding, sourceDomain: nil, unadjusted: nil))
        shownReferenceOptions = referenceOptions
        source = PhotoSource(domain: reference.source.domain, unadjusted: reference.unadjusted,
                             colorSource: reference.source.colorSource,
                             hasCaptureMetadata: reference.hasCaptureMetadata)
        edit = EditSnapshot(EditBaseline.initial(encoding: encoding, preview: reference))
        let models = photoModels()
        if !models.contains(where: { $0.id == edit.selectedModel && $0.isEnabled }) {
            let table = services.modelTable()
            edit.selectedModel = models.first(where: { $0.id == table.defaultID && $0.isEnabled })?.id
                ?? models.first(where: \.isEnabled)?.id ?? edit.selectedModel
        }
        runEncoding = edit.encoding
        lastJob = RenderJob(options: effectiveOptions(), draft: false)
        displayedAIGain = nil
        readyGain = nil
        gainToken = nil
        aiFailureReason = nil
        ai.update(fallbackMissingFields: [])
        setSplitRatioValue(0.5)
        setPeeking(false)
        notice = nil
        clearUndo()
        scopes.update(original: .some(nil), current: .some(nil), waveform: .some(nil))
        syncControls()
        revalidateGain()
    }

    /// No photo: the controls show the defaults and are disabled.
    func endEditing() {
        invalidateDetails()
        hideMask()
        source = PhotoSource()
        edit = EditSnapshot(EditDefaults.initial(encoding: runEncoding, sourceDomain: nil, unadjusted: nil))
        lastJob = nil
        displayedAIGain = nil
        readyGain = nil
        gainToken = nil
        aiFailureReason = nil
        setSplitRatioValue(0.5)
        setPeeking(false)
        notice = nil
        scopeTask?.cancel()
        originalScopeTask?.cancel()
        scopes.update(original: .some(nil), current: .some(nil), waveform: .some(nil))
        clearUndo()
        syncControls()
    }

    /// After any change to `edit` other than a slider: publish, render,
    /// and check whether the AI gain still applies.
    func editChanged() {
        invalidateDetails(editedOnly: true)
        followLensCorrectionWithReference()
        runEncoding = edit.encoding
        rememberOutputPreferences()
        syncControls()
        revalidateGain()
        scheduleRender()
    }

    // MARK: - Publishing

    /// Writes the value objects from `edit` and the lock. Each object only
    /// changes the properties whose value differs.
    func syncControls() {
        let locked = isEditingLocked || photo == nil
        syncExportState()
        let snapshot = edit
        let defaults = defaultsForCurrentEncoding()
        setWorkflowValue(snapshot.workflow)
        for spec in EditControls.all {
            guard let control = controlValues[spec.key] else { continue }
            let dragging = gesture?.key == spec.key
            control.update(value: snapshot.controls[spec.key], defaultValue: defaults.controls[spec.key],
                           range: dragging ? nil : ControlRules.range(control.spec, encoding: snapshot.encoding,
                                                                   domain: source.domain),
                           isVisible: spec.key == "quality" ? snapshot.encoding != "sdr-tiff" : ControlRules.isVisible(spec.key, workflow: snapshot.workflow,
                                                             domain: source.domain, aiMode: snapshot.aiMode),
                           isEnabled: !locked)
        }
        let tagged = source.colorSource != nil && source.colorSource != "assumed"
        inputColor.update(selection: snapshot.choices["colorGamut"] ?? "srgb",
                          isVisible: document != nil && source.domain != .sceneReferred,
                          isEnabled: !locked && !tagged && source.colorSource != nil,
                          disabledReasonKey: .some(tagged ? "inputColor.disabled.tagged" : nil))
        if let maskKey, (controlValues[maskKey]?.isVisible != true || controlValues[maskKey]?.isEnabled != true) {
            hideMask()
        }
        syncLUTState()
        updateAIState()
    }

    /// Queues a render of the current values unless the scheduler already has
    /// exactly this one. `force` re-renders the same values (a new edge).
    func scheduleRender(draft: Bool = false, force: Bool = false) {
        refreshExportMetadata()
        guard photo != nil, document?.phase == .ready, !ai.isComputing else { return }
        var job = RenderJob(options: effectiveOptions(), draft: draft)
        guard force || job != lastJob else { return }
        job.trace = PreviewTrace()
        lastJob = job
        clearPreviewError()
        requestBusy()
        renderScheduler?.update(job)
    }
}

extension EditorModel {
    static func undoActionName(_ action: String) -> String {
        switch action {
        case "brightness": String(localized: "undo.brightness")
        case "hdrStrength": String(localized: "undo.hdrStrength")
        case "hdrRange": String(localized: "undo.hdrRange")
        case "lutStrength": String(localized: "undo.lutStrength")
        case "modelStrength": String(localized: "undo.modelStrength")
        case "aiBrightness": String(localized: "undo.aiBrightness")
        case "aiContrast": String(localized: "undo.aiContrast")
        case "aiShadows": String(localized: "undo.aiShadows")
        case "aiHighlights": String(localized: "undo.aiHighlights")
        case "aiHdrRange": String(localized: "undo.aiHdrRange")
        case "aiExpansionStart": String(localized: "undo.aiExpansionStart")
        case "expansionStart": String(localized: "undo.expansionStart")
        case "areaCoverage": String(localized: "undo.areaCoverage")
        case "workflow": String(localized: "undo.workflow")
        case "encoding": String(localized: "undo.encoding")
        case "inputColor": String(localized: "undo.inputColor")
        case "aiMode": String(localized: "undo.aiMode")
        case "lensCorrection": String(localized: "undo.lensCorrection")
        case "model": String(localized: "undo.model")
        case "reset": String(localized: "undo.reset")
        default: String(localized: "undo.adjust")
        }
    }
}
