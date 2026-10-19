import Foundation
import Observation

enum AIAvailability: Equatable, Sendable {
    /// Can be switched on; the gain still has to be computed.
    case available
    /// The gain for the current settings is computed; switching on is instant.
    case cached
    case applied(modelName: String)
    /// Not ready, an HDR source, colour-only, an HDR / log LUT input, …
    case unavailable(reasonKey: String)
}

/// One selectable model. `nameKey` / `summaryKey` are xcstrings keys
/// (`model.<id>` from the engine's `displayKey`); `name` is the engine's own
/// display name for logs and the fallback.
struct ModelChoice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let nameKey: String
    let summaryKey: String
    var isEnabled: Bool
    /// Needs the photo's capture parameters (shown only when it has them).
    let requiresCapture: Bool
    /// The engine's version of the model (`entry.document["version"]`).
    var version: String? = nil
}

/// The model table the services offer for this engine build.
struct ModelTable: Equatable, Sendable {
    var runtimeReady: Bool
    var defaultID: String
    var models: [ModelChoice]

    static let unavailable = ModelTable(runtimeReady: false, defaultID: "", models: [])
}

/// Opaque identity of a computed model gain (Kit's `ModelGainKey`): equal
/// tokens mean the gain computed for one still applies to the other.
struct ModelGainToken: Hashable, @unchecked Sendable {
    let value: AnyHashable
}

/// A computed gain: its identity, and the capture fields the model had to
/// do without (it fell back to pixels only).
struct ModelGainOutcome: Equatable, Sendable {
    let token: ModelGainToken
    let missingCaptureFields: [String]
}

@MainActor @Observable final class AIState {
    private(set) var mode: AIMode = .manual
    private(set) var availability: AIAvailability = .unavailable(reasonKey: "ai.unavailable.noPhoto")
    private(set) var isComputing = false
    /// Models for this photo; a single enabled one means the view hides the picker.
    private(set) var models: [ModelChoice] = []
    private(set) var selectedModel = ""
    private(set) var fallbackMissingFields: [String] = []

    /// Model only.
    func update(mode: AIMode? = nil, availability: AIAvailability? = nil, isComputing: Bool? = nil,
                models: [ModelChoice]? = nil, selectedModel: String? = nil,
                fallbackMissingFields: [String]? = nil) {
        if let mode, mode != self.mode { self.mode = mode }
        if let availability, availability != self.availability { self.availability = availability }
        if let isComputing, isComputing != self.isComputing { self.isComputing = isComputing }
        if let models, models != self.models { self.models = models }
        if let selectedModel, selectedModel != self.selectedModel { self.selectedModel = selectedModel }
        if let fallbackMissingFields, fallbackMissingFields != self.fallbackMissingFields {
            self.fallbackMissingFields = fallbackMissingFields
        }
    }
}
