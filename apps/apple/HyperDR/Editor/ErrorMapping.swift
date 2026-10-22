import Foundation
import HyperDREngine
import HyperDRKit
import HyperDRRender

extension UserFacingError {
    /// A service-layer error keeps its §3.6 code; the message is the
    /// developer-facing detail, never shown as the title.
    init(_ error: HyperDRError) {
        if error.code == "raw_unsupported" {
            guard case .object(let fields) = error.detail,
                  case .string(let container) = fields["container"],
                  container == "camera" || container == "dng" else {
                self.init(code: error.code, variant: "camera")
                return
            }
            let model: String?
            if case .string(let value) = fields["model"], !value.isEmpty { model = value }
            else { model = nil }
            self.init(code: error.code, detail: model, variant: container)
        } else if error.code == "unsupported_format", case .object(let fields) = error.detail,
                  fields["container"] == .string("heif"), case .string(let feature) = fields["feature"] {
            // The reader says which HEIF feature it cannot read. A known one gets its own sentence and
            // no engine wording; an unknown one keeps the detail for a bug report.
            if ErrorText.heifFeatures.contains(feature) {
                self.init(code: error.code, variant: "heif_" + feature)
            } else {
                self.init(code: error.code, detail: error.messageDetail ?? error.message, variant: "heif_unknown")
            }
        } else if error.code == "export_folder_unwritable",
                  case .object(let fields) = error.detail, fields["save_mode"] == .string("destination") {
            self.init(code: error.code, detail: error.messageDetail ?? error.message, variant: "destination")
        } else {
            self.init(code: error.code, detail: error.messageDetail ?? error.message)
        }
    }

    /// Any error from the services: typed errors keep their code, the rest are
    /// internal and carry their description as detail.
    static func service(_ error: any Error) -> UserFacingError {
        switch error {
        case let error as UserFacingError: error
        case let error as HyperDRError: UserFacingError(error)
        case let error as RecipeExportError: UserFacingError(error)
        case let error as EditorRenderingError: UserFacingError(error)
        case let error as RenderError: UserFacingError(error)
        case is CancellationError: UserFacingError(code: "cancelled")
        default: UserFacingError(code: "internal_error", detail: String(describing: error))
        }
    }

    /// Kit's recipe export failures (P7-3b-K) under the codes the export
    /// messages already have.
    init(_ error: RecipeExportError) {
        switch error {
        case .busy: self.init(code: "convert_in_progress")
        case .invalidSnapshot: self.init(code: "invalid_options")
        case .sourceChanged: self.init(code: "source_changed")
        case .missingLUT: self.init(code: "lut_invalid")
        case .missingModel: self.init(code: "model_not_ready")
        case .memoryExceeded(let reason):
            if case .memory(let required, let available, _, let edge) = reason {
                self.init(code: "export_memory_budget", detail: "required \(required) bytes, available \(available)",
                          suggestedLongEdge: edge)
            } else { self.init(code: "export_memory_budget") }
        // The plan's blocker codes, under the messages that already say them;
        // the plan's own message keys are not in the catalogue.
        case .planBlocked(let reasons):
            let detail = "plan blocked: " + reasons.joined(separator: ", ")
            if reasons.contains("export_memory_exceeded") { self.init(code: "export_memory_budget", detail: detail) }
            else if reasons.contains("unsupported_format") { self.init(code: "unsupported_format", detail: detail) }
            else { self.init(code: "export_failed", detail: detail) }
        case .verificationFailed(let detail): self.init(code: "export_failed", detail: "verification failed: " + detail)
        case .invalidStripes: self.init(code: "export_failed", detail: "invalid stripes")
        }
    }

    /// Render's failures, which the export service and its readers pass on
    /// as they are (R36-003).
    init(_ error: RenderError) {
        switch error {
        case .sourceChanged: self.init(code: "source_changed")
        case .cannotOpenSource: self.init(code: "source_unreadable")
        case .cannotDecodeSource, .missingGainMap, .unsupportedGainColorSpace, .unsupportedRAWDecoder:
            self.init(code: "decode_failed", detail: String(describing: error))
        case .allocationFailed: self.init(code: "out_of_memory")
        case .metalUnavailable: self.init(code: "metal_unavailable")
        case .gpu(let detail): self.init(code: "metal_unavailable", detail: detail)
        case .aiNotAvailable: self.init(code: "model_not_ready")
        case .invalidLUT(let detail): self.init(code: "lut_invalid", detail: detail)
        case .invalidSize, .invalidRegion, .invalidAdjustment, .duplicateHDRSplit:
            self.init(code: "internal_error", detail: String(describing: error))
        }
    }

    /// What the editor could not capture for an export.
    init(_ error: EditorRenderingError) {
        switch error {
        case .missingLUT(let hash): self.init(code: "lut_invalid", detail: hash)
        case .sourceChanged: self.init(code: "source_changed")
        default: self.init(code: "internal_error", detail: String(describing: error))
        }
    }

    /// A failure to obtain a file before it reaches `open`: the open panel's
    /// result or a drag provider. Nil when the user cancelled, which is not an
    /// error (§3.6; A2 error entry point).
    static func importFailure(_ error: any Error) -> UserFacingError? {
        switch error {
        case is CancellationError: return nil
        case let error as UserFacingError:
            return error
        case let error as HyperDRError:
            return UserFacingError(error)
        case let error as CocoaError:
            switch error.code {
            case .userCancelled:
                return nil
            case .fileReadUnsupportedScheme:
                // Not a file URL (for example a web link dragged in).
                return UserFacingError(code: "unsupported_format", detail: error.localizedDescription)
            default:
                // Permission (257 / 513), missing file (4 / 260), unknown read
                // failures (256) and provider failures: the file cannot be read.
                return UserFacingError(code: "source_unreadable", detail: error.localizedDescription)
            }
        default:
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == CocoaError.userCancelled.rawValue {
                return nil
            }
            return UserFacingError(code: "source_unreadable", detail: error.localizedDescription)
        }
    }
}
