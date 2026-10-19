import Foundation
import HyperDREngine

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
        case is CancellationError: UserFacingError(code: "cancelled")
        default: UserFacingError(code: "internal_error", detail: String(describing: error))
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
