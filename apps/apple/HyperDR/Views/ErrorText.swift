import SwiftUI

/// What the user reads for a `UserFacingError`: a short title and a sentence
/// that says what happened, keyed by the error's code (batch 3 §3.6).
///
/// The engine's or system's own wording (`detail`) is never translated and is
/// only ever the secondary line. A code this table does not know gets the
/// generic text with the code itself, so a new error is still reported.
struct ErrorText {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    /// The untranslated detail, when there is one and the message does not
    /// already carry it.
    let detail: String?

    init(_ error: UserFacingError) {
        let detail = error.detail.flatMap { $0.isEmpty ? nil : $0 }
        if let entry = Self.entries[error.code] {
            title = entry.title
            if entry.messageTakesDetail, let detail {
                message = entry.messageWithDetail(detail)
                self.detail = nil
            } else {
                message = entry.message
                self.detail = detail
            }
        } else {
            title = "mac.err.generic.title"
            message = "mac.err.generic.message \(error.code)"
            self.detail = detail
        }
    }

    /// Message and detail as one block, for an alert body or a tooltip.
    var body: String {
        let message = String(localized: message)
        guard let detail else { return message }
        return message + "\n\n" + String(localized: "mac.err.detail \(detail)")
    }

    /// Whether the code is one this table describes; the rest fall back to
    /// the generic text.
    static func isKnown(_ code: String) -> Bool { entries[code] != nil }

    private struct Entry {
        let title: LocalizedStringResource
        let message: LocalizedStringResource
        /// For codes whose detail is a value the sentence names (the actual
        /// extension, the two camera models) rather than an engine message.
        var withDetail: ((String) -> LocalizedStringResource)? = nil
        var messageTakesDetail: Bool { withDetail != nil }

        func messageWithDetail(_ detail: String) -> LocalizedStringResource {
            withDetail?(detail) ?? message
        }
    }

    // One row per code in §3.6, in its order. Message keys reuse the web
    // panel's `err.server.<code>` family; titles are native-only.
    private static let entries: [String: Entry] = [
        "cancelled": Entry(title: "mac.err.cancelled.title", message: "err.server.cancelled"),
        "busy": Entry(title: "mac.err.busy.title", message: "err.server.busy"),
        "raw_budget": Entry(title: "mac.err.raw_budget.title", message: "err.server.raw_budget"),
        "invalid_options": Entry(title: "mac.err.invalid_options.title", message: "err.server.invalid_options"),
        "out_of_memory": Entry(title: "mac.err.out_of_memory.title", message: "err.server.out_of_memory"),
        "internal_error": Entry(title: "mac.err.internal_error.title", message: "err.server.internal_error"),
        "source_unreadable": Entry(title: "mac.err.source_unreadable.title", message: "err.server.source_unreadable"),
        "unsupported_format": Entry(title: "mac.err.unsupported_format.title", message: "err.server.unsupported_format"),
        "decode_failed": Entry(title: "mac.err.decode_failed.title", message: "err.server.decode_failed"),
        "input_extension_mismatch": Entry(title: "mac.err.input_extension_mismatch.title",
            message: "err.server.input_extension_mismatch",
            withDetail: { "err.server.input_extension_mismatch.actual \($0)" }),
        "file_empty": Entry(title: "mac.err.file_empty.title", message: "err.server.file_empty"),
        "source_missing": Entry(title: "mac.err.source_missing.title", message: "err.server.source_missing"),
        "preview_timeout": Entry(title: "mac.err.preview_timeout.title", message: "err.server.preview_timeout"),
        "engine_unavailable": Entry(title: "mac.err.engine_unavailable.title", message: "err.server.engine_unavailable"),
        "metal_unavailable": Entry(title: "mac.err.metal_unavailable.title", message: "err.server.metal_unavailable"),
        "session_expired": Entry(title: "mac.err.session_expired.title", message: "err.server.session_expired"),
        "convert_in_progress": Entry(title: "mac.err.convert_in_progress.title", message: "err.server.convert_in_progress"),
        "model_not_ready": Entry(title: "mac.err.model.title", message: "err.server.model_not_ready"),
        "model_unknown": Entry(title: "mac.err.model.title", message: "err.server.model_unknown"),
        "export_folder_unset": Entry(title: "mac.err.export_folder_unset.title", message: "err.server.export_folder_unset"),
        "export_folder_unwritable": Entry(title: "mac.err.export_folder_unwritable.title", message: "err.server.export_folder_unwritable"),
        "export_folder_inside_workspace": Entry(title: "mac.err.export_folder_inside_workspace.title",
            message: "err.server.export_folder_inside_workspace"),
        "lut_invalid": Entry(title: "mac.err.lut_invalid.title", message: "err.server.lut_invalid"),
        "lut_too_large": Entry(title: "mac.err.lut_too_large.title", message: "err.server.lut_too_large"),
        "dcp_invalid": Entry(title: "mac.err.dcp_invalid.title", message: "err.server.dcp_invalid"),
        "dcp_camera_mismatch": Entry(title: "mac.err.dcp_camera_mismatch.title", message: "err.server.dcp_camera_mismatch"),
        "dcp_requires_raw": Entry(title: "mac.err.dcp_requires_raw.title", message: "err.server.dcp_requires_raw"),
        "look_requires_profile": Entry(title: "mac.err.look_requires_profile.title", message: "err.server.look_requires_profile"),
        "look_unsupported": Entry(title: "mac.err.look_unsupported.title", message: "err.server.look_unsupported"),
        "profile_root_unreadable": Entry(title: "mac.err.profile_root_unreadable.title", message: "err.server.profile_root_unreadable"),
        "hevc_unavailable": Entry(title: "mac.err.hevc.title", message: "err.server.hevc_unavailable"),
        "hevc_main10_unavailable": Entry(title: "mac.err.hevc.title", message: "err.server.hevc_main10_unavailable"),
        "hevc_probe_failed": Entry(title: "mac.err.hevc.title", message: "err.server.hevc_probe_failed"),
        "hevc_encode_failed": Entry(title: "mac.err.hevc_encode_failed.title", message: "err.server.hevc_encode_failed"),
    ]
}
