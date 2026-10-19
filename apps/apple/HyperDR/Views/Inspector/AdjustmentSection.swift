import SwiftUI
import HyperDRDesign

/// "Processing mode": colour-only or HDR enhancement, with a line saying what
/// the chosen one does.
struct WorkflowSection: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionHeading("workflow.title")
            ParameterSegmented("workflow.title", selection: workflow, choices: [
                SegmentedChoice("workflow.color", value: Workflow.colorOnly, systemImage: "paintpalette"),
                SegmentedChoice("workflow.hdr", value: Workflow.hdr, systemImage: "sun.max"),
            ])
            Text(model.workflow == .hdr ? "workflow.hdrHint" : "workflow.colorHint")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
        }
        .padding(20)
        .disabled(!model.canSetWorkflow)
    }

    private var workflow: Binding<Workflow> {
        Binding(get: { model.workflow }, set: { next in
            model.clearAIFailureNotice()
            model.setWorkflow(next)
        })
    }
}

/// "Image adjustments": the reset button, manual or AI, what AI is doing and
/// the controls of the mode in use. The groups that follow (fine-tune,
/// affected area, LUT) are full-width and sit under it in the inspector.
struct AdjustmentSection: View {
    let model: EditorModel
    @Environment(\.locale) private var locale

    var body: some View {
        let panel = AIPanelState.make(
            domain: model.document?.source?.domain, mode: model.ai.mode, availability: model.ai.availability,
            isComputing: model.ai.isComputing, fallbackMissingFields: model.ai.fallbackMissingFields,
            notice: model.notice)
        VStack(alignment: .leading, spacing: Space.s4) {
            header
            if panel.showsModeSwitch {
                ParameterSegmented("adjust.mode", selection: aiMode, choices: [
                    SegmentedChoice("inspector.manual", value: AIMode.manual, systemImage: "slider.horizontal.3"),
                    panel.isComputing
                        ? SegmentedChoice(Text("ai.segment.computing"), value: AIMode.optimized,
                                          systemImage: "sparkles", isEnabled: false)
                        : SegmentedChoice("adjust.ai", value: AIMode.optimized, systemImage: "sparkles",
                                          isEnabled: panel.isAIEnabled),
                ])
                .disabled(model.isEditingLocked)
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(Array(panel.lines.enumerated()), id: \.offset) { _, line in
                    InspectorNotice(text(for: line), style: line.style)
                }
            }
            if model.ai.mode == .optimized { ModelPicker(model: model) }
            ForEach(Self.keys, id: \.self) { ControlSlider(model: model, key: $0) }
        }
        .padding(20)
        .task(id: model.notice) { await clearResetNoticeSoon() }
    }

    /// The controls shown directly: the manual tone group, then the AI model's.
    static let keys = ["brightness", "hdrStrength", "hdrRange", "modelStrength", "aiBrightness", "aiContrast"]

    private var header: some View {
        HStack {
            SectionHeading("inspector.adjustments")
            Spacer()
            SectionResetButton("adjust.reset", doneTitle: "adjust.resetDone", isDone: model.notice == .resetDone) {
                model.resetAll()
            }
            .disabled(!model.canResetAll)
            .help("adjust.resetTitle")
        }
    }

    private var aiMode: Binding<AIMode> {
        Binding(get: { model.ai.mode }, set: { next in
            model.clearAIFailureNotice()
            model.setAIMode(next)
        })
    }

    /// "All reset" stays for 1.5 s, then the button is "Reset" again.
    private func clearResetNoticeSoon() async {
        guard model.notice == .resetDone else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        if !Task.isCancelled, model.notice == .resetDone { model.notice = nil }
    }

    private func text(for line: AIPanelState.Line) -> Text {
        switch line {
        case .manualNote: Text("inspector.manualNote")
        case .hdrSource: Text("ai.status.hdrSource")
        case .cached: Text("ai.status.cached")
        case .computing: Text("ai.status.computing")
        case .applied(let nameKey): Text("ai.status.applied \(AppStrings.string(nameKey, locale: locale))")
        case .fallback(let fields):
            Text("ai.fallback \(Self.fieldList(fields, locale: locale)) \(AppStrings.string(model.fallbackModelNameKey, locale: locale))")
        case .failed(let reasonKey): Text("ai.status.failed \(AppStrings.string(reasonKey, locale: locale))")
        case .unavailable(let reasonKey): Text("ai.status.unavailable \(AppStrings.string(reasonKey, locale: locale))")
        }
    }

    /// "aperture and focal length" / 「光圈和焦距」.
    static func fieldList(_ fields: [String], locale: Locale) -> String {
        fields.map { AppStrings.string("field.\($0)", locale: locale) }
            .formatted(.list(type: .and, width: .standard).locale(locale))
    }
}

extension EditorModel {
    /// What the fall-back after missing capture data is called: the model
    /// that needs the image only.
    var fallbackModelNameKey: String {
        ai.models.first { !$0.requiresCapture }?.nameKey ?? "model.research-cnn-v1"
    }

    /// A failed AI attempt stays in view until the user switches manual / AI
    /// or the processing mode (design §3); the next such change clears it.
    func clearAIFailureNotice() {
        if case .aiFailed? = notice { notice = nil }
    }
}

/// The model menu and the line about the chosen one; hidden unless there is
/// a choice (A-02).
private struct ModelPicker: View {
    let model: EditorModel

    var body: some View {
        let choices = model.ai.models.filter(\.isEnabled)
        if choices.count >= 2 {
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack {
                    Text("ai.model")
                        .font(Font.hdr.control)
                        .foregroundStyle(Color.hdr.ink)
                    Spacer()
                    Picker("ai.model", selection: Binding(get: { model.ai.selectedModel },
                                                          set: { model.selectModel($0) })) {
                        ForEach(choices) { Text(LocalizedStringKey($0.nameKey)).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(model.isEditingLocked)
                }
                if let chosen = choices.first(where: { $0.id == model.ai.selectedModel }) {
                    Text(LocalizedStringKey(chosen.summaryKey))
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The AI model's four fine adjustments, in a group of their own: only in AI
/// mode, open by default.
struct FineTuneGroup: View {
    let model: EditorModel
    @State private var isExpanded = true

    var body: some View {
        if model.control("aiShadows").isVisible {
            ParameterGroup("ai.fineTune", systemImage: "dial.medium", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    ForEach(["aiShadows", "aiHighlights", "aiHdrRange", "aiExpansionStart"], id: \.self) {
                        ControlSlider(model: model, key: $0)
                    }
                }
                .padding(.top, Space.s3)
            }
        }
    }
}

/// "Affected area": where HDR expansion starts and how much broad bright
/// areas weigh. Hidden with colour-only processing, AI and HDR sources.
struct RegionGroup: View {
    let model: EditorModel
    @State private var isExpanded = true

    var body: some View {
        if model.control("expansionStart").isVisible {
            ParameterGroup("adjust.region", systemImage: "square.dashed.inset.filled", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    ForEach(["expansionStart", "areaCoverage"], id: \.self) { ControlSlider(model: model, key: $0) }
                    Text("inspector.regionNote")
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkMuted)
                }
                .padding(.top, Space.s3)
            }
        }
    }
}
