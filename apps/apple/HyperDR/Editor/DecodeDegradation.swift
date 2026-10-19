import SwiftUI

/// What the user is told when the engine read a photo with limits: its reason
/// identifiers (`ultrahdr_decode_failed_sdr_fallback`, …) are not for people.
/// Every reason the engine gives today means the same thing: the photo's HDR
/// data (the gain map) could not be used and it was treated as a standard
/// photo. The detail after a colon (a decoder's own message) belongs only in
/// the copied diagnostics.
nonisolated enum DecodeDegradation {
    static let hdrUnusableKey = "warn.decode.hdrUnusable"
    static let otherKey = "warn.decode.other"

    /// The reasons whose prefixes mean "the HDR data couldn't be used".
    private static let hdrUnusable: Set<String> = [
        "ultrahdr_decode_failed_sdr_fallback", "gain_map_metadata_duplicate",
        "avif_gain_map_pixels_unavailable_sdr_fallback", "avif_gain_map_apply_failed_sdr_fallback",
        "apple_legacy_gain_map_unusable_sdr_fallback",
    ]

    /// The string key for one reason: its part before the first colon decides.
    static func key(for reason: String) -> String {
        let prefix = reason.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? reason
        return hdrUnusable.contains(prefix) ? hdrUnusableKey : otherKey
    }

    static func text(_ reason: String) -> LocalizedStringKey { LocalizedStringKey(key(for: reason)) }

    /// The one sentence for all the reasons, or nil when there are none. They
    /// describe the same event, so more than one is never shown; "the HDR data
    /// couldn't be used" is the more specific.
    static func key(for reasons: [String]) -> String? {
        guard !reasons.isEmpty else { return nil }
        return reasons.contains { key(for: $0) == hdrUnusableKey } ? hdrUnusableKey : otherKey
    }

    static func text(_ reasons: [String]) -> LocalizedStringKey? { key(for: reasons).map { LocalizedStringKey($0) } }
}
