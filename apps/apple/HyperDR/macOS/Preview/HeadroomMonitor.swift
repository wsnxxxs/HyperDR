import AppKit
import os

// `HeadroomSnapshot` is shared with iOS (Shared/Canvas/EDRDisplayPass.swift).

/// Diagnostic A/B/C comparison. Production defaults to the currently usable
/// headroom; neither the potential value nor a model's throttled readout can
/// silently replace it. C's system activation still needs display validation.
nonisolated enum HeadroomPolicy: String {
    case current = "A", potential = "B", declaredCurrent = "C"
    static let configured = Self(rawValue: UserDefaults.standard.string(forKey: "HDRHeadroomPolicy") ?? "A") ?? .current
    func target(_ snapshot: HeadroomSnapshot) -> Double {
        Double(self == .potential ? snapshot.potential : snapshot.current)
    }
}

/// NSScreen is read only on the main actor, once per display tick and on screen
/// notifications. This state is independent of EditorModel's 4Hz readout.
@MainActor final class HeadroomMonitor {
    private static let logger = Logger(subsystem: "com.hyperdr.HyperDR", category: "PreviewTiming")
    private(set) var snapshot = HeadroomSnapshot()
    @discardableResult func sample(_ screen: NSScreen?) -> Bool {
        update(screen.map { HeadroomSnapshot(screen: $0.localizedName,
            current: $0.maximumExtendedDynamicRangeColorComponentValue,
            potential: $0.maximumPotentialExtendedDynamicRangeColorComponentValue,
            reference: $0.maximumReferenceExtendedDynamicRangeColorComponentValue) } ?? HeadroomSnapshot())
    }
    @discardableResult func update(_ value: HeadroomSnapshot) -> Bool {
        guard snapshot != value else { return false }
        snapshot = value
        if HeadroomPolicy.configured != .current {
            Self.logger.info("A3 headroom current=\(Double(value.current), privacy: .public) potential=\(Double(value.potential), privacy: .public) policy=\(HeadroomPolicy.configured.rawValue, privacy: .public)")
        }
        return true
    }
}
