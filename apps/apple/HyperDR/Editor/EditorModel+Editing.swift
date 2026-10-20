import Foundation
import AppKit
import HyperDRKit
import HyperDRRecipe

/// What the open photo told the model about itself.
struct PhotoSource: Equatable {
    var domain: InputDomain?
    var colorSource: String?
    var hasCaptureMetadata = false
}

extension EditorModel {
    // MARK: - Lock

    /// One switch for everything that must not change the photo: before the
    /// first frame, while opening or restoring, while exporting (batch4
    /// §2.12). AI no longer locks anything (p7-adjustments §3). Control
    /// enablement, undo and open derive from it; views never combine their
    /// own conditions.
    var editingLockReason: EditingLockReason? {
        if export.isInFlight { return .exporting }
        if isRestoring { return .restoring }
        guard document != nil else { return nil }
        if !hasEditedFrame || document?.phase != .ready || photo == nil { return .loading }
        return nil
    }
    var isEditingLocked: Bool { editingLockReason != nil }

    /// User commands stay enabled in an empty workspace and for replacing
    /// a ready/failed photo. Finder/drop/programmatic open can supersede an
    /// in-progress open (Q14).
    var photoSwitch: PhotoSwitchPolicy {
        if export.isInFlight { return .confirmStoppingExport }
        if isRestoring { return .unavailable(reasonKey: "export.blocker.restoring") }
        if document?.phase == .opening || document?.phase == .rendering { return .unavailable(reasonKey: "export.blocker.loading") }
        return .allowed
    }
    var canOpenDocument: Bool {
        if case .unavailable = photoSwitch { return false }; return true
    }

    var canResetAll: Bool { photo != nil && !isEditingLocked }

    /// The editor's Reset All, from the menu.
    func resetAll() {
        guard canResetAll else { return }
        editor.resetAll()
    }

    /// The processing mode of the export: colour-only or HDR, from its encoding.
    var workflow: Workflow { exportChoices.workflow }

    /// The export's quality as its summary shows it; nil for TIFF.
    var exportQuality: Double? {
        exportChoices.encoding == "sdr-tiff" ? nil : exportChoices.quality
    }

    func setExportQuality(_ value: Double) {
        guard photo != nil, !isEditingLocked, value.isFinite else { return }
        let quality = min(100, max(0, value.rounded()))
        guard exportChoices.quality != quality else { return }
        exportChoices.quality = quality
        exportChoicesChanged()
    }

    // MARK: - Undo (batch4 §2.4, p7-2b §4)

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

    /// A drag still open can be undone: Undo ends it as its own step first
    /// (R22-004).
    var canUndo: Bool {
        _ = undoRevision
        return !isEditingLocked && (undoManager.canUndo || editor.isDragging)
    }

    var canRedo: Bool {
        _ = undoRevision
        return !isEditingLocked && !editor.isDragging && undoManager.canRedo
    }

    /// The menu's "Undo Change Exposure".
    var undoActionName: String { _ = undoRevision; return undoManager.undoActionName }
    var redoActionName: String { _ = undoRevision; return undoManager.redoActionName }

    func undo() {
        guard canUndo else { return }
        editor.commitDrag()
        undoManager.undo()
        bumpUndoRevision()
    }

    func redo() {
        guard canRedo else { return }
        editor.commitDrag()
        undoManager.redo()
        bumpUndoRevision()
    }

    func clearUndo() {
        editor.undo.clear()
        bumpUndoRevision()
    }

    /// Every discrete command first commits the active drag.
    func finishGestureBeforeEdit() { editor.commitDrag() }

    // MARK: - Photo lifetime

    /// The opened photo: the editor starts it from its domain's defaults; the
    /// export request starts from the run's encoding; view state resets.
    func beginEditing(encoding: String, source editorSource: EditorSource) {
        invalidateDetails()
        commit(source: editorSource)
        source = PhotoSource(domain: SourceSummary(editorSource).domain)
        exportChoices.encoding = encoding
        runEncoding = encoding
        setSplitRatioValue(0.5)
        setPeeking(false)
        notice = nil
        scopedRequest = nil; scopingRequest = nil
        scopedOriginal = nil; scopingOriginal = nil
        scopes.update(original: .some(nil), current: .some(nil), waveform: .some(nil))
        canvas.setImageSize(PixelSize(editorSource.pixelSize))
        bumpUndoRevision()
        syncControls()
    }

    /// No photo: the inspector shows the welcome.
    func endEditing() {
        invalidateDetails()
        setMaskKey(nil)
        source = PhotoSource()
        setSplitRatioValue(0.5)
        setPeeking(false)
        notice = nil
        scopeTask?.cancel()
        originalScopeTask?.cancel()
        scopedRequest = nil; scopingRequest = nil
        scopedOriginal = nil; scopingOriginal = nil
        scopes.update(original: .some(nil), current: .some(nil), waveform: .some(nil))
        clearUndo()
        syncControls()
    }

    /// After a change of the export request (encoding, output gamut, clamp).
    func exportChoicesChanged() {
        runEncoding = exportChoices.encoding
        rememberOutputPreferences()
        syncControls()
        refreshExportMetadata()
    }

    // MARK: - Publishing

    /// The export state and the LUT selection, from the editor and the request.
    func syncControls() {
        syncExportState()
        syncLUTState()
        canvasGeometryChanged()
    }

    /// The output format. The export interface (M3) switches it; it is not an
    /// edit and has no undo step.
    func selectEncoding(_ id: String) {
        guard photo != nil, !isEditingLocked, (export.encodingAvailability[id] ?? nil) == nil, id != exportChoices.encoding,
              ExportEncoding(rawValue: id) != nil else { return }
        exportChoices.encoding = id
        exportChoicesChanged()
    }
}
