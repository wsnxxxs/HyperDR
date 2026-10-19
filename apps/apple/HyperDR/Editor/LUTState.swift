import Foundation
import Observation
import HyperDRKit

nonisolated enum LUTColorSpace: String, CaseIterable, Sendable {
    case srgb, p3, rec709, hlg, pq
    case slog3SGamut3Cine = "slog3-sgamut3cine"
}
nonisolated struct LUTItem: Identifiable, Equatable, Sendable {
    var id: String; var name: String; var input: LUTColorSpace; var output: LUTColorSpace
    var byteCount: UInt64 = 0
}
@MainActor @Observable final class LUTState {
    var library: [LUTItem] = []
    var selection: LUTItem?
    var isEnabled = true
    var spaceIssueKey: String?
    var isBusy = false
    var importBlocker: String? { importBlockerKey }
    var importBlockerKey: String?
    var failures: [UserFacingError] = []
}
nonisolated struct EditorCapabilities: Sendable {
    struct Encoding: Sendable { var available: Bool; var reason: String }
    var encodings: [String: Encoding]
    var main8: Bool
    var main10: Bool
    var encoderReason: String?
    func availability(isHDR: Bool) -> [String: String?] {
        var result: [String: String?] = [:]
        for id in Preferences.encodings {
            var reason: String? = encodings[id].map { $0.available ? nil : $0.reason } ?? "hevc_unavailable"
            if id == "adaptive" && !(isHDR ? main10 : main8) || ["pq", "hlg"].contains(id) && !main10 {
                reason = encoderReason ?? (isHDR || id != "adaptive" ? "hevc_main10_unavailable" : "hevc_unavailable")
            }
            let key = reason.map { ["hevc_unavailable", "hevc_main10_unavailable", "hevc_probe_failed"].contains($0)
                ? "err.server.\($0)" : "err.server.hevc_unavailable" }
            result[id] = .some(key)
        }
        return result
    }
}
