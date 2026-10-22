import HyperDRDesign
import Observation

/// What the views remember for this run of the app and nothing longer: the
/// scope panel's kind, channels and whether it is open, and how often each
/// canvas hint has been shown (M2 design §5, §9). All windows share it. It
/// is not `@SceneStorage` or a preference on purpose: both outlive the run.
@MainActor @Observable final class ViewerSessionState {
    static let shared = ViewerSessionState()

    var scopeKind: ScopeKind = .histogram
    var scopeChannels: HistogramChannels = .luma
    var isScopeExpanded = true

    /// Each hint is shown at most this many times in a run.
    static let hintLimit = 2

    @ObservationIgnored private var hintCounts: [String: Int] = [:]

    func hintCount(_ key: String) -> Int { hintCounts[key, default: 0] }

    /// Takes one showing of `key`'s hint: true, and counted, while it has
    /// been shown fewer than `hintLimit` times.
    func claimHint(_ key: String) -> Bool {
        guard hintCount(key) < Self.hintLimit else { return false }
        hintCounts[key, default: 0] += 1
        return true
    }
}
