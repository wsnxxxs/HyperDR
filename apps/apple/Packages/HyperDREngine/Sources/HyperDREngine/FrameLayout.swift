import Foundation
import HyperDREngineCore

/// Pixel geometry of a presentation frame, as `hyperdr_frame_layout` returns
/// it. The caption band spans the canvas width from the photo's bottom edge
/// to the canvas bottom; an export's caption overlay is exactly its size.
public struct FrameLayout: Codable, Sendable, Hashable {
    public struct Rect: Codable, Sendable, Hashable {
        public let x, y, width, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }
    public let schema: String
    public let width, height: Int
    public let photo, caption: Rect
    /// The photo edge, in pixels, that the frame's fractions measure.
    public let referenceEdge: Int
}

/// Where a framed export placed its photograph (the report's `frame` record).
public struct ReportFrame: Codable, Sendable, Hashable {
    public let width, height: Int
    public let photo: FrameLayout.Rect
}

extension Engine {
    /// The layout of a hyperdr.frame/v1 document around a photo of the given
    /// oriented pixel size. Pure computation, safe from any thread.
    ///
    /// Export recomputes this from the rendered photo, so size the caption
    /// overlay with the export's own dimensions (after any size limit), not
    /// with a preview's.
    public static func frameLayout(frame: [String: JSONValue], photoWidth: Int,
                                   photoHeight: Int) throws -> FrameLayout {
        guard (1...Int(UInt32.max)).contains(photoWidth), (1...Int(UInt32.max)).contains(photoHeight) else {
            throw HyperDRError(code: "invalid_options", message: "Photo dimensions must be positive")
        }
        let bytes = try encodeJSON(frame).withCString { input in
            try jsonResult { hyperdr_frame_layout(input, UInt32(photoWidth), UInt32(photoHeight), $0, $1) }
        }
        return try decodeJSON(FrameLayout.self, bytes)
    }
}
