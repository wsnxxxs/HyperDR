import HyperDRDesign

/// What the "Manual / AI enhance" part of the inspector shows for one state
/// of the model: whether the switch is there and usable, and the lines under
/// it, in order. One pure function, so each state in the design (M2 §3) has a
/// test and the view only draws what this says.
struct AIPanelState: Equatable {
    enum Line: Equatable {
        /// The hint for manual editing.
        case manualNote
        /// The photo carries HDR itself: no AI, no affected area.
        case hdrSource
        /// A gain for these settings is computed; switching on is instant.
        case cached
        case computing
        /// AI is applied; the key is the model's display name.
        case applied(modelNameKey: String)
        /// The model fell back to the image alone for these capture fields.
        case fallback(fields: [String])
        /// The last computation failed and AI went back to manual.
        case failed(reasonKey: String)
        /// AI cannot run now; the key says why.
        case unavailable(reasonKey: String)

        var style: InspectorNotice.Style {
            switch self {
            case .manualNote, .hdrSource, .cached, .unavailable: .info
            case .computing: .progress
            case .applied: .success
            case .fallback, .failed: .warning
            }
        }
    }

    /// An HDR source has no switch at all (A-01).
    var showsModeSwitch: Bool
    var isAISelected: Bool
    /// Whether the AI segment can be chosen; false while it computes.
    var isAIEnabled: Bool
    var isComputing: Bool
    var lines: [Line]

    static func make(domain: InputDomain?, mode: AIMode, availability: AIAvailability, isComputing: Bool,
                     fallbackMissingFields: [String], notice: EditorNotice?) -> AIPanelState {
        if domain == .hdr || domain == .dual {
            return AIPanelState(showsModeSwitch: false, isAISelected: false, isAIEnabled: false,
                                isComputing: false, lines: [.hdrSource])
        }
        var lines: [Line] = []
        var canChooseAI = true
        if case .unavailable = availability { canChooseAI = false }
        if isComputing {
            lines = [.computing]
        } else if mode == .optimized {
            canChooseAI = true
            if case .applied(let name) = availability {
                lines.append(.applied(modelNameKey: name))
                if !fallbackMissingFields.isEmpty { lines.append(.fallback(fields: fallbackMissingFields)) }
            }
        } else if case .aiFailed(let reason)? = notice {
            // The failure outranks the plain "unavailable" it leaves behind.
            lines = [.failed(reasonKey: reason)]
        } else {
            switch availability {
            case .available: lines = [.manualNote]
            case .cached: lines = [.cached]
            case .unavailable(let reason): lines = [.unavailable(reasonKey: reason)]
            case .applied: break
            }
        }
        return AIPanelState(showsModeSwitch: true, isAISelected: mode == .optimized,
                            isAIEnabled: canChooseAI && !isComputing, isComputing: isComputing, lines: lines)
    }
}
