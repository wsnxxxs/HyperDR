import Foundation
import HyperDREngine
import HyperDRKit

/// AI optimisation (batch4 §2.6). The gain's identity is the Kit's
/// `ModelGainKey` (its `ModelGainInputs` table); the model only remembers
/// which identity is ready and compares, so the rule for what invalidates a
/// gain lives in one place.
extension EditorModel {
    /// Switches between manual and AI; one undo step. Ignored while AI
    /// cannot run (matching the disabled control).
    func setAIMode(_ mode: AIMode) {
        guard !isEditingLocked, mode != edit.aiMode else { return }
        if mode == .optimized, aiBlockReason() != nil || aiFailureReason != nil { return }
        finishGestureBeforeEdit()
        let previous = edit
        edit.aiMode = mode
        recordStep(from: previous, action: "aiMode")
        syncControls()
        if mode == .optimized { ensureGain() } else { scheduleRender() }
    }

    /// One undo step; a different model needs its own gain.
    func selectModel(_ id: String) {
        guard !isEditingLocked, id != edit.selectedModel,
              ai.models.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        finishGestureBeforeEdit()
        let previous = edit
        edit.selectedModel = id
        aiFailureReason = nil
        recordStep(from: previous, action: "model")
        editChanged()
    }

    /// The models for this photo: one that needs capture parameters appears
    /// only when the photo has them (PC A-02).
    func photoModels() -> [ModelChoice] {
        services.modelTable().models.filter { !$0.requiresCapture || source.hasCaptureMetadata }
    }

    /// Why AI cannot run now, as a string key; nil when it can.
    func aiBlockReason(workflow: Workflow? = nil) -> String? {
        guard photo != nil, hasEditedFrame else { return "ai.unavailable.noPhoto" }
        let table = services.modelTable()
        guard table.runtimeReady, photoModels().contains(where: \.isEnabled) else {
            return "ai.unavailable.modelNotReady"
        }
        if source.domain == .hdr || source.domain == .dual { return "ai.unavailable.hdrSource" }
        if (workflow ?? edit.workflow) == .colorOnly { return "ai.unavailable.colorOnly" }
        let lutInput = edit.choices["lutInput"] ?? "srgb"
        if !["srgb", "p3", "rec709"].contains(lutInput) { return "ai.unavailable.lutInput" }
        return nil
    }

    func updateAIState() {
        let models = photo == nil ? [] : photoModels()
        let availability: AIAvailability
        if let reason = aiBlockReason() ?? aiFailureReason {
            availability = .unavailable(reasonKey: reason)
        } else if gainToken != nil, gainToken == readyGain, !ai.isComputing {
            if edit.aiMode == .optimized, displayedAIGain == readyGain {
                availability = .applied(modelName: models.first { $0.id == edit.selectedModel }?.nameKey
                                        ?? edit.selectedModel)
            } else {
                availability = .cached
            }
        } else {
            availability = .available
        }
        ai.update(mode: edit.aiMode, availability: availability, models: models,
                  selectedModel: edit.selectedModel)
    }

    /// After a change that may touch the model's inputs. In AI mode a stale
    /// gain is recomputed; in manual mode only the availability is updated.
    func revalidateGain() {
        tokenTask?.cancel()
        guard let photo, document?.phase == .ready, aiBlockReason() == nil else {
            if edit.aiMode == .optimized, aiBlockReason() != nil {
                edit.aiMode = .manual
                syncControls()
                scheduleRender()
            }
            updateAIState()
            return
        }
        if edit.aiMode == .optimized {
            ensureGain()
            return
        }
        let options = edit.options(aiMode: .optimized)
        let ticket = aiTicket
        tokenTask = Task { [weak self, services] in
            let token = try? await services.modelGainToken(for: photo, options: options)
            guard let self, !Task.isCancelled, aiTicket == ticket, self.photo == photo else { return }
            gainToken = token
            updateAIState()
        }
    }

    /// Makes the gain for the current values ready, then renders with it.
    /// Editing is locked meanwhile; a failure returns to manual.
    func ensureGain() {
        guard let photo else { return }
        aiTask?.cancel()
        tokenTask?.cancel()
        renderScheduler?.discard()
        lastJob = nil
        setRefreshing(false)
        aiTicket += 1
        let ticket = aiTicket
        let options = edit.options(aiMode: .optimized)
        ai.update(isComputing: true)
        syncControls()
        aiTask = Task { [weak self, services] in
            do {
                let token = try await services.modelGainToken(for: photo, options: options)
                guard let self, self.aiTicket == ticket, !Task.isCancelled else { return }
                gainToken = token
                if token != readyGain {
                    let outcome = try await services.computeModelGain(for: photo, options: options)
                    guard self.aiTicket == ticket, !Task.isCancelled else { return }
                    readyGain = outcome.token
                    gainToken = outcome.token
                    ai.update(fallbackMissingFields: outcome.missingCaptureFields)
                }
                finishComputing()
                scheduleRender()
            } catch {
                guard let self, self.aiTicket == ticket, !Task.isCancelled else { return }
                failAI(error)
            }
        }
    }

    func failAI(_ error: any Error) {
        let reason = Self.aiReasonKey(error)
        aiFailureReason = reason
        edit.aiMode = .manual
        finishComputing()
        notice = .aiFailed(reasonKey: reason)
        scheduleRender()
    }

    private func finishComputing() {
        aiTask = nil
        ai.update(isComputing: false)
        syncControls()
    }

    /// Stops any gain work (new photo, close, canvas failure).
    func cancelAI() {
        aiTask?.cancel()
        tokenTask?.cancel()
        aiTask = nil
        aiTicket += 1
        ai.update(isComputing: false)
    }

    static func aiReasonKey(_ error: any Error) -> String {
        switch (error as? UserFacingError)?.code ?? (error as? HyperDRError)?.code {
        case "model_not_ready": "ai.unavailable.modelNotReady"
        case "model_unknown": "ai.unavailable.unknownModel"
        default: "ai.unavailable.failed"
        }
    }
}
