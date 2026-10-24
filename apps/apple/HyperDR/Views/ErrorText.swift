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
            title = error.variant.flatMap { entry.titleVariants[$0] } ?? entry.title
            let shown = entry.showsDetail ? detail : nil
            if let variant = error.variant, let text = entry.variants[variant] {
                message = text
                self.detail = shown
            } else if entry.messageTakesDetail, let detail {
                message = entry.messageWithDetail(detail)
                self.detail = nil
            } else {
                message = entry.message
                self.detail = shown
            }
        } else {
            title = "mac.err.generic.title"
            message = "mac.err.generic.message \(error.code)"
            self.detail = detail
        }
    }

    /// Message and detail as one block, for an alert body or a tooltip.
    var body: String { body(locale: .current) }

    /// The same block in the language of `locale`.
    func body(locale: Locale) -> String {
        var message = self.message, detailLabel = LocalizedStringResource("mac.err.detail \(detail ?? "")")
        message.locale = locale; detailLabel.locale = locale
        let text = String(localized: message)
        guard detail != nil else { return text }
        return text + "\n\n" + String(localized: detailLabel)
    }

    /// The title in the language of `locale`.
    func title(locale: Locale) -> String {
        var title = self.title
        title.locale = locale
        return String(localized: title)
    }

    /// Whether the code is one this table describes; the rest fall back to
    /// the generic text.
    static func isKnown(_ code: String) -> Bool { entries[code] != nil }

    /// The features the HEIF reader reports with `unsupported_format`
    /// (`modules/container`, `modules/codec/src/hevc`); each has a sentence.
    nonisolated static let heifFeatures = ["protected_item", "construction_method", "external_reference", "image_sequence", "handler", "essential_property", "codec", "hevc_444", "hevc_422", "hevc_chroma", "hevc_12bit", "hevc_bit_depth", "hevc_decoder", "hevc_separate_planes", "hevc_parameter_change", "color_matrix"]

    private struct Entry {
        let title: LocalizedStringResource
        let message: LocalizedStringResource
        /// For codes whose detail is a value the sentence names (the actual
        /// extension, the two camera models) rather than an engine message.
        var withDetail: ((String) -> LocalizedStringResource)? = nil
        /// Sentences for an error's `variant` (the model's context for it:
        /// whether the export had a frame, whether it was colour-only).
        var variants: [String: LocalizedStringResource] = [:]
        /// Titles for the variants that name a different problem.
        var titleVariants: [String: LocalizedStringResource] = [:]
        /// Whether a detail the message does not carry is shown below it.
        var showsDetail = true
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
        // A HEIF the reader refuses names the feature (`UserFacingError.init(_:)` marks it `heif_<feature>`):
        // the sentence says what is missing, and the engine's own wording stays out of the alert.
        // A feature this table does not know gets `heif_unknown`, whose engine detail still shows.
        "unsupported_format": Entry(title: "mac.err.unsupported_format.title", message: "err.server.unsupported_format",
            variants: [
                "heif_protected_item": "err.server.unsupported_format.heif.protected_item",
                "heif_construction_method": "err.server.unsupported_format.heif.construction_method",
                "heif_external_reference": "err.server.unsupported_format.heif.external_reference",
                "heif_image_sequence": "err.server.unsupported_format.heif.image_sequence",
                "heif_handler": "err.server.unsupported_format.heif.handler",
                "heif_essential_property": "err.server.unsupported_format.heif.essential_property",
                "heif_codec": "err.server.unsupported_format.heif.codec",
                "heif_hevc_444": "err.server.unsupported_format.heif.hevc_444",
                "heif_hevc_422": "err.server.unsupported_format.heif.hevc_422",
                "heif_hevc_chroma": "err.server.unsupported_format.heif.hevc_chroma",
                "heif_hevc_12bit": "err.server.unsupported_format.heif.hevc_12bit",
                "heif_hevc_bit_depth": "err.server.unsupported_format.heif.hevc_bit_depth",
                "heif_hevc_decoder": "err.server.unsupported_format.heif.hevc_decoder",
                "heif_hevc_separate_planes": "err.server.unsupported_format.heif.hevc_separate_planes",
                "heif_hevc_parameter_change": "err.server.unsupported_format.heif.hevc_parameter_change",
                "heif_color_matrix": "err.server.unsupported_format.heif.color_matrix",
                "heif_unknown": "err.server.unsupported_format.heif.unknown",
            ],
            titleVariants: Dictionary(uniqueKeysWithValues: (Self.heifFeatures + ["unknown"]).map {
                ("heif_" + $0, LocalizedStringResource("mac.err.unsupported_format.heif.title")) })),
        "decode_failed": Entry(title: "mac.err.decode_failed.title", message: "err.server.decode_failed"),
        "raw_decoder_unavailable": Entry(title: "mac.err.raw_decoder_unavailable.title",
            message: "err.server.raw_decoder_unavailable",
            withDetail: { "err.server.raw_decoder_unavailable.version \($0)" }),
        "input_extension_mismatch": Entry(title: "mac.err.input_extension_mismatch.title",
            message: "err.server.input_extension_mismatch",
            withDetail: { "err.server.input_extension_mismatch.actual \($0)" }),
        "file_empty": Entry(title: "mac.err.file_empty.title", message: "err.server.file_empty"),
        "source_missing": Entry(title: "mac.err.source_missing.title", message: "err.server.source_missing"),
        "source_changed": Entry(title: "source.changed.title", message: "export.blocker.sourceChanged"),
        "preview_timeout": Entry(title: "mac.err.preview_timeout.title", message: "err.server.preview_timeout"),
        "engine_unavailable": Entry(title: "mac.err.engine_unavailable.title", message: "err.server.engine_unavailable"),
        "metal_unavailable": Entry(title: "mac.err.metal_unavailable.title", message: "err.server.metal_unavailable"),
        "session_expired": Entry(title: "mac.err.session_expired.title", message: "err.server.session_expired"),
        "convert_in_progress": Entry(title: "mac.err.convert_in_progress.title", message: "err.server.convert_in_progress"),
        "model_not_ready": Entry(title: "mac.err.model.title", message: "err.server.model_not_ready"),
        "model_unknown": Entry(title: "mac.err.model.title", message: "err.server.model_unknown"),
        "export_folder_unset": Entry(title: "mac.err.export_folder_unset.title", message: "err.server.export_folder_unset"),
        // The model marks a place chosen in the save panel (`destination`); the unmarked one is the fixed folder.
        "export_folder_unwritable": Entry(title: "mac.err.export_folder_unwritable.title", message: "err.server.export_folder_unwritable",
            variants: ["destination": "err.server.export_folder_unwritable.destination"]),
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
        // The model tells whether the export had a frame; an unmarked one is read as without.
        "export_memory_budget": Entry(title: "mac.err.export_memory_budget.title",
            message: "err.server.export_memory_budget.noFrame",
            variants: ["frame": "err.server.export_memory_budget.frame",
                       "noFrame": "err.server.export_memory_budget.noFrame"]),
        "export_dimension_limit": Entry(title: "mac.err.export_dimension_limit.title",
            message: "err.server.export_dimension_limit",
            variants: ["color": "err.server.export_dimension_limit.color",
                       "avif": "err.server.export_dimension_limit.avif"]),
        // The camera model rides in the sentence (`withDetail`); a DNG has its own title and sentence.
        // Nothing is appended below either: the detail is only the model.
        "raw_unsupported": Entry(title: "mac.err.raw_unsupported.title", message: "err.server.raw_unsupported",
            withDetail: { "err.server.raw_unsupported.model \($0)" },
            variants: ["dng": "err.server.raw_unsupported.dng"],
            titleVariants: ["dng": "mac.err.raw_unsupported.dng.title"], showsDetail: false),
        "export_failed": Entry(title: "mac.err.export_failed.title", message: "err.server.export_failed"),
        // The byte counts are diagnostics; the sentence says what to do.
        "export_storage_full": Entry(title: "mac.err.export_storage_full.title", message: "err.server.export_storage_full",
            showsDetail: false),
        "convert_timeout": Entry(title: "mac.err.convert_timeout.title", message: "err.server.convert_timeout"),
    ]
}
