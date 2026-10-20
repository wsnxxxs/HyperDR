import Foundation

extension UserFacingError {
    /// Frontend ErrorText may prefer this key; errors remain independent of
    /// the current editor values when the exported snapshot has since changed.
    var messageVariantKey: String? {
        switch (code, variant) {
        case ("export_memory_budget", "frame"): "err.server.export_memory_budget.frame"
        case ("export_memory_budget", "noFrame"): "err.server.export_memory_budget.noFrame"
        case ("export_dimension_limit", "color"): "err.server.export_dimension_limit.color"
        case ("export_dimension_limit", "avif"): "err.server.export_dimension_limit.avif"
        case ("export_dimension_limit", _): "err.server.export_dimension_limit"
        case ("raw_unsupported", "dng"): "err.server.raw_unsupported.dng"
        case ("raw_unsupported", _) where detail != nil: "err.server.raw_unsupported.model %@"
        case ("raw_unsupported", _): "err.server.raw_unsupported"
        case ("export_folder_unwritable", "destination"): "err.server.export_folder_unwritable.destination"
        case ("export_failed", _): "err.server.export_failed"
        case ("convert_timeout", _): "err.server.convert_timeout"
        default: nil
        }
    }
}
extension EditorNotice {
    var messageKey: String? {
        switch self {
        case .clipboardImageUnsupported: "paste.imageData"
        case .rangeClamped: "export.rangeClamped %@ %@"
        }
    }
}
