import AppKit
import HyperDREngine
import os

nonisolated struct HeadroomSnapshot: Equatable, Sendable {
    var screen: String? = nil
    var current: CGFloat = 1
    var potential: CGFloat = 1
    var reference: CGFloat = 1
}

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

nonisolated enum GainWeight {
    static let rebuildThreshold: Float = 0.005
    static func value(headroom: Double, base: Double, alternate: Double) -> Float {
        let denominator = alternate - base
        guard headroom.isFinite, headroom > 1, base.isFinite, alternate.isFinite,
              abs(denominator) >= 1e-8 else { return 0 }
        return Float(min(1, max(0, (log2(headroom) - base) / denominator)))
    }
    static func value(headroom: Double, metadata: PreviewMetadata) -> Float {
        value(headroom: headroom, base: metadata.baseHeadroom ?? 0,
              alternate: metadata.alternateHeadroom ?? metadata.headroomStops)
    }
    /// Compare with the last *rendered* weight, so small steps accumulate.
    /// Endpoints are exact: never leave a residual HDR contribution on SDR.
    static func needsRebuild(from old: Float?, to new: Float) -> Bool {
        guard let old else { return true }
        return abs(new - old) > rebuildThreshold || (new != old && (new == 0 || new == 1))
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
        if PreviewTrace.recordsEnabled {
            Self.logger.info("A3 headroom current=\(Double(value.current), privacy: .public) potential=\(Double(value.potential), privacy: .public) policy=\(HeadroomPolicy.configured.rawValue, privacy: .public)")
        }
        return true
    }
}
