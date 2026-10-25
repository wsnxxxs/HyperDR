import Foundation
import HyperDREngineCore

/// Metadata retained from LibRaw's unpack, before CIRAWFilter develops the DNG.
public struct RAWConversionReport: Codable, Sendable {
    public let converter: String
    /// `cfa` or `linear`.
    public let layout: String
    public let make: String
    public let model: String
    /// Default crop before orientation.
    public let width: Int
    public let height: Int
    public let orientation: Int
}

/// Dimensions and EXIF orientation of the extracted embedded JPEG.
public struct RAWPreviewReport: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let orientation: Int
}

extension Engine {
    /// Stable identity of the LibRaw snapshot and DNG serialization format.
    public static var rawConverterID: String { String(cString: hyperdr_raw_converter_id()) }

    /// Unpacks a camera RAW as a DNG without demosaicing it. The engine creates
    /// the output exclusively and publishes it atomically. Runs on the engine
    /// queue and forwards Task cancellation to the native operation.
    public func convertRAWToDNG(_ source: URL, to output: URL) async throws -> RAWConversionReport {
        try await EngineExecutor.run { cancellation in
            let bytes = try source.path.withCString { rawPath in
                try output.path.withCString { dngPath in
                    try jsonResult {
                        hyperdr_raw_convert_dng(self.pointer, rawPath, dngPath,
                                                cancellation.pointer, $0, $1)
                    }
                }
            }
            return try decodeJSON(RAWConversionReport.self, bytes)
        }
    }

    /// Extracts the largest embedded JPEG without altering its encoded bytes.
    /// Runs on the engine queue and forwards Task cancellation.
    public func extractRAWPreview(_ source: URL, to output: URL) async throws -> RAWPreviewReport {
        try await EngineExecutor.run { cancellation in
            let bytes = try source.path.withCString { rawPath in
                try output.path.withCString { jpegPath in
                    try jsonResult {
                        hyperdr_raw_extract_preview(self.pointer, rawPath, jpegPath,
                                                    cancellation.pointer, $0, $1)
                    }
                }
            }
            return try decodeJSON(RAWPreviewReport.self, bytes)
        }
    }
}
