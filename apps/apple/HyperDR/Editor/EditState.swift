import Foundation
import HyperDREngine
import HyperDRKit
import Observation

/// Colour-only (SDR output) or HDR, derived from the output encoding.
enum Workflow: Equatable, Sendable {
    case colorOnly, hdr

    init(encoding: String) { self = EditBaseline.isSDR(encoding) ? .colorOnly : .hdr }
}

enum AIMode: Equatable, Sendable {
    case manual, optimized
}

/// Everything one undo step restores (batch4 §2.4): the request values, the
/// processing mode (through `encoding`), AI mode, model and input colour.
/// View state (mode, zoom, split, overlays) and the frame are not in it.
struct EditSnapshot: Equatable, Sendable {
    /// One value per `EditControls` key.
    var controls: [String: Double]
    /// One id per `EditChoices` key; `colorGamut` is the input colour.
    var choices: [String: String]
    var clampSrgb: Bool
    var lensCorrection: Bool
    var aiMode: AIMode
    var selectedModel: String

    var encoding: String { choices["encoding"] ?? "adaptive" }
    var workflow: Workflow { Workflow(encoding: encoding) }

    init(_ options: EditOptions, aiMode: AIMode = .manual) {
        var controls: [String: Double] = [:]
        for spec in EditControls.all {
            if case .number(let value)? = options[spec.key] { controls[spec.key] = value }
            else { controls[spec.key] = spec.defaultValue }
        }
        var choices: [String: String] = [:]
        for spec in EditChoices.all {
            if case .string(let id)? = options[spec.key] { choices[spec.key] = id }
            else { choices[spec.key] = spec.defaultID }
        }
        self.controls = controls
        self.choices = choices
        if case .bool(let value)? = options["clampSrgb"] { clampSrgb = value } else { clampSrgb = false }
        if case .bool(let value)? = options["lensCorrection"] { lensCorrection = value } else { lensCorrection = true }
        if case .string(let id)? = options["modelId"] { selectedModel = id } else { selectedModel = "" }
        self.aiMode = aiMode
    }

    /// AI post-adjustments and the model strength act only in AI mode.
    static let aiKeys: Set<String> = Set(EditControls.all.filter { $0.group == .model }.map(\.key))

    /// The request in the panel vocabulary. Settings the panel-v1 adapter
    /// fills (highlight recovery, contrast, vibrance, quality) stay out, and
    /// the AI keys are sent only in AI mode, so changing them in manual mode
    /// leaves the request, and the frame, unchanged.
    func options(aiMode mode: AIMode? = nil) -> EditOptions {
        let mode = mode ?? aiMode
        var values: [String: JSONValue] = [:]
        for (key, value) in controls where mode == .optimized || !Self.aiKeys.contains(key) {
            values[key] = .number(value)
        }
        for (key, id) in choices { values[key] = .string(id) }
        values["clampSrgb"] = .bool(clampSrgb)
        values["lensCorrection"] = .bool(lensCorrection)
        if mode == .optimized {
            values["useModel"] = .bool(true)
            if !selectedModel.isEmpty { values["modelId"] = .string(selectedModel) }
        }
        return EditOptions(values)
    }
}

/// The starting values of an open, shared by the live services (which render
/// the first edit frame with them) and the model (which shows them), so both
/// derive the same values from the same reference frame.
enum EditBaseline {
    static func isSDR(_ encoding: String) -> Bool { encoding == "sdr-jpeg" || encoding == "sdr-tiff" }

    static func initial(encoding: String, domain: InputDomain?,
                        unadjusted: [String: Double]?) -> EditOptions {
        EditDefaults.initial(encoding: encoding, sourceDomain: domain?.rawValue, unadjusted: unadjusted)
    }

    static func initial(encoding: String, preview: EditorPreview) -> EditOptions {
        initial(encoding: encoding, domain: preview.source.domain, unadjusted: preview.unadjusted)
    }

    /// The highest hdrRange / aiHdrRange the encoding accepts.
    static func maxRange(for encoding: String) -> Double { EditDefaults.maxRange(for: encoding) }
}

// MARK: - Control description for views

/// How a control's readout is written; mirrors `ControlSpec.Format` so views
/// never import the Kit.
enum ControlFormat: String, Sendable {
    case ev, signed, percent, fixed2, stops1, stopsOrAuto1, percentOrAuto, integer

    /// The smallest step of the readout, in value units (§2.2).
    var resolution: Double {
        switch self {
        case .ev, .signed, .fixed2, .percent, .percentOrAuto: 0.01
        case .stops1, .stopsOrAuto1: 0.1
        case .integer: 1
        }
    }

    /// `value` rounded to the readout's resolution, without binary noise.
    func quantize(_ value: Double) -> Double {
        let steps = (value / resolution).rounded()
        return Double(String(format: "%.4f", steps * resolution)) ?? steps * resolution
    }
}

enum ControlGroup: String, Sendable { case lut, tone, model, region }

/// The read-only description a view needs to draw one slider.
struct ControlSpecView: Equatable, Sendable {
    let key: String
    let group: ControlGroup
    let labelKey: String
    let helpKey: String?
    let format: ControlFormat
    let step: Double
    let defaultValue: Double
    let isPercent: Bool
    let allowsAuto: Bool
    let hasMask: Bool
    /// The static range; `ControlValue.range` is the effective one.
    let range: ClosedRange<Double>

    init(_ spec: ControlSpec) {
        key = spec.key
        group = ControlGroup(rawValue: spec.group.rawValue) ?? .tone
        labelKey = spec.labelKey
        helpKey = spec.helpKey
        format = ControlFormat(rawValue: spec.format.rawValue) ?? .fixed2
        step = spec.step
        defaultValue = spec.defaultValue
        isPercent = spec.isPercent
        allowsAuto = spec.allowsAuto
        hasMask = spec.mask != nil
        range = spec.range
    }
}

/// One continuous control. The object for a key never changes while the
/// model lives; only the model writes its state (batch3 §3.4, batch4 §2.2).
@MainActor @Observable final class ControlValue {
    let key: String
    let spec: ControlSpecView
    private(set) var value: Double
    private(set) var range: ClosedRange<Double>
    private(set) var isVisible = true
    private(set) var isEnabled = false

    var isAuto: Bool { spec.allowsAuto && value < 0 }

    init(spec: ControlSpecView) {
        key = spec.key
        self.spec = spec
        value = spec.defaultValue
        range = spec.range
    }

    /// Model only. Writes only what changed, so observers of one property are
    /// not invalidated by another.
    func update(value: Double? = nil, range: ClosedRange<Double>? = nil,
                isVisible: Bool? = nil, isEnabled: Bool? = nil) {
        if let value, value != self.value { self.value = value }
        if let range, range != self.range { self.range = range }
        if let isVisible, isVisible != self.isVisible { self.isVisible = isVisible }
        if let isEnabled, isEnabled != self.isEnabled { self.isEnabled = isEnabled }
    }
}

/// One option of a discrete setting, with why it is unavailable.
struct Choice<ID: Hashable & Sendable>: Equatable, Sendable {
    let id: ID
    let labelKey: String
    var isEnabled: Bool
    var disabledReasonKey: String?
}

@MainActor @Observable final class ChoiceValue<ID: Hashable & Sendable> {
    let key: String
    private(set) var selection: ID
    private(set) var choices: [Choice<ID>]
    private(set) var isVisible = true
    private(set) var isEnabled = false
    /// Why the whole setting is unavailable (for example, the file states
    /// its own colour).
    private(set) var disabledReasonKey: String?

    init(key: String, selection: ID, choices: [Choice<ID>]) {
        self.key = key
        self.selection = selection
        self.choices = choices
    }

    func update(selection: ID? = nil, choices: [Choice<ID>]? = nil, isVisible: Bool? = nil,
                isEnabled: Bool? = nil, disabledReasonKey: String?? = nil) {
        if let selection, selection != self.selection { self.selection = selection }
        if let choices, choices != self.choices { self.choices = choices }
        if let isVisible, isVisible != self.isVisible { self.isVisible = isVisible }
        if let isEnabled, isEnabled != self.isEnabled { self.isEnabled = isEnabled }
        if let disabledReasonKey, disabledReasonKey != self.disabledReasonKey {
            self.disabledReasonKey = disabledReasonKey
        }
    }
}

/// A one-shot message the view shows in place (not an alert).
enum EditorNotice: Equatable {
    case resetDone
    /// AI could not run; it went back to manual. The key explains why.
    case aiFailed(reasonKey: String)
}

/// Which controls show, as one pure function (batch4 §2.2). Colour-only
/// hides the HDR controls, region and AI; an HDR source hides region and AI;
/// AI mode swaps the manual HDR controls for the model's.
enum ControlRules {
    static let hdrKeys: Set<String> = ["hdrStrength", "hdrRange"]
    static let regionKeys: Set<String> = ["expansionStart", "areaCoverage"]

    static func isVisible(_ key: String, workflow: Workflow, domain: InputDomain?,
                          aiMode: AIMode) -> Bool {
        let hdrSource = domain == .hdr || domain == .dual
        let model = EditSnapshot.aiKeys.contains(key)
        if workflow == .colorOnly {
            return !hdrKeys.contains(key) && !regionKeys.contains(key) && !model
        }
        if hdrSource && (regionKeys.contains(key) || model) { return false }
        if model { return aiMode == .optimized }
        if aiMode == .optimized && (hdrKeys.contains(key) || regionKeys.contains(key)) { return false }
        return true
    }

    /// The effective range for this encoding and source (Web `controls.js`):
    /// brightness goes below 0 only for an HDR source (lowering its own
    /// rendering; an SDR or RAW base has nothing to darken into), and the HDR
    /// range stops at the encoding's ceiling.
    static func range(_ spec: ControlSpecView, encoding: String, domain: InputDomain?) -> ClosedRange<Double> {
        var range = spec.range
        switch spec.key {
        case "brightness":
            if domain != .hdr && domain != .dual {
                range = max(0, range.lowerBound)...range.upperBound
            }
        case "hdrRange", "aiHdrRange":
            range = range.lowerBound...min(range.upperBound, EditBaseline.maxRange(for: encoding))
        default: break
        }
        return range
    }
}
