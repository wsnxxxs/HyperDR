import Foundation

/// Presentation values; RAW environment identity is supplied by engine metadata.
/// nil means no RAW decoder has been identified for the current photograph.
nonisolated struct AboutInformation: Equatable, Sendable {
    var version = ""
    var buildNumber = ""
    var engineABI: UInt32?
    /// The engine's export memory budget, from its capabilities.
    var memoryBudgetBytes: UInt64?
    var osBuild: String?
    var decoderVersion: String?

    init() {}
    init(bundle: Bundle, engineABI: UInt32, memoryBudgetBytes: UInt64? = nil) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        self.engineABI = engineABI
        self.memoryBudgetBytes = memoryBudgetBytes
    }
}
