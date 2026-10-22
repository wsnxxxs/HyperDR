import Foundation
import os

/// What the editing core reports for diagnostics, under the app's subsystem.
/// Lines name stages, sizes, decoder versions, error types and enum cases;
/// never file names, paths or picture content. A host may also `mirror` each
/// line, as the iOS app does to keep recent launches for its diagnostics export.
nonisolated enum EditorLog {
    typealias Mirror = @Sendable (_ isError: Bool, _ line: String) -> Void

    private static let logger = Logger(subsystem: "com.hyperdr.HyperDR", category: "Editor")
    private static let sink = OSAllocatedUnfairLock<Mirror?>(initialState: nil)

    static func mirror(_ handler: Mirror?) { sink.withLock { $0 = handler } }

    static func notice(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        sink.withLock { $0 }?(false, line)
    }

    static func error(_ line: String) {
        logger.error("\(line, privacy: .public)")
        sink.withLock { $0 }?(true, line)
    }

    /// "HyperDRKit.RecipeExportError.verificationFailed(heif_gain_readback)" or
    /// "NSCocoaErrorDomain 260": the kind of failure, with a value it carries
    /// only when that is a short code; anything else may hold a path.
    static func describe(_ error: any Error) -> String {
        let type = String(reflecting: Swift.type(of: error))
        if error is CocoaError || Swift.type(of: error) is NSError.Type {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
        let text = String(describing: error)
        let name = text.prefix { $0 != "(" && $0 != " " && $0 != ":" && $0 != "\"" }
        guard !name.isEmpty, !type.hasSuffix(".\(name)"), type != name else { return type }
        guard text.hasPrefix("\(name)(\""), text.hasSuffix("\")") else { return "\(type).\(name)" }
        let value = text.dropFirst(name.count + 2).dropLast(2)
        let isCode = value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
        return isCode ? "\(type).\(name)(\(value))" : "\(type).\(name)"
    }
}
