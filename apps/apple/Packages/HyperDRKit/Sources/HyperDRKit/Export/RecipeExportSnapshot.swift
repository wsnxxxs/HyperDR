import CryptoKit
import Foundation
import HyperDRRecipe
import HyperDRRender

/// Frozen editing intent. Paths, preview bypasses and display headroom are excluded.
public struct RecipeExportSnapshot: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public let version: Int
    public let recipe: Recipe
    public let source: RecipeSourceRevision
    public let modelID: String?
    public let frame: RecipeFrameSnapshot?
    public var lutContentHash: String? { recipe.look?.contentHash }

    public init(recipe: Recipe, source: RecipeSourceRevision, modelID: String? = nil,
                frame: FrameSnapshot? = nil) {
        version = Self.currentVersion; self.recipe = recipe; self.source = source
        self.modelID = modelID; self.frame = frame.map(RecipeFrameSnapshot.init)
    }
}

/// Capture when the editor opens the source, not when export starts.
public struct RecipeSourceRevision: Sendable, Codable, Equatable {
    public let sha256: String
    public let byteCount: Int64
    public let modificationDate: Date
    public init(sha256: String, byteCount: Int64, modificationDate: Date) {
        self.sha256 = sha256; self.byteCount = byteCount; self.modificationDate = modificationDate
    }
    public init(session: PhotoSession) throws {
        let values = try session.sourceURL.resourceValues(forKeys: [.contentModificationDateKey])
        self.init(sha256: session.sha256, byteCount: session.byteCount,
                  modificationDate: values.contentModificationDate ?? .distantPast)
    }
}

/// Codable representation of Render's frame, including the frozen caption bytes.
public struct RecipeFrameSnapshot: Sendable, Codable, Equatable {
    public let width, height: Int
    public let photo: [Int]
    public let paper: SIMD3<Float>
    public let shadowOpacity, shadowSigma: Float
    public let shadowOffset: SIMD2<Float>
    public let captionPNG: Data?
    public let captionRect: [Int]?
    public init(_ frame: FrameSnapshot) {
        width = frame.canvasSize.width; height = frame.canvasSize.height
        photo = [frame.photo.x, frame.photo.y, frame.photo.width, frame.photo.height]
        paper = frame.paper; shadowOpacity = frame.shadow.opacity; shadowSigma = frame.shadow.sigma
        shadowOffset = frame.shadow.offset; captionPNG = frame.caption?.png
        captionRect = frame.caption.map { [$0.rect.x, $0.rect.y, $0.rect.width, $0.rect.height] }
    }
    public func renderFrame() throws -> FrameSnapshot {
        guard width > 0, height > 0, photo.count == 4,
              captionRect == nil || captionRect?.count == 4 else {
            throw RecipeExportError.invalidSnapshot
        }
        func rect(_ a: [Int]) -> ExportRect { .init(x: a[0], y: a[1], width: a[2], height: a[3]) }
        let caption = captionPNG.flatMap { png in captionRect.map { FrameCaption(png: png, rect: rect($0)) } }
        return FrameSnapshot(canvasSize: .init(width: width, height: height), photo: rect(photo), paper: paper,
                             shadow: .init(opacity: shadowOpacity, sigma: shadowSigma, offset: shadowOffset), caption: caption)
    }
}

/// The actual output contract, frozen separately from editable intent.
public struct ResolvedExportSnapshot: Sendable, Codable, Equatable {
    public let snapshot: RecipeExportSnapshot
    public let selection: ExportChoice
    public let profileVersion: Int
    public let renderContractVersion: Int
    public let encoding: ExportEncoding
    public let writer: ExportWriter
    public let gamut: ExportColorGamut
    public let bitDepth, quality, width, height: Int
    public let ceilingStops: Double?
    public let resolvedAutomatic: [String: Double]
    public let resplitReasons: [String]
    public init(snapshot: RecipeExportSnapshot, plan: ExportPlan,
                resolvedAutomatic: [String: Double] = [:], resplitReasons: [String] = []) {
        self.snapshot = snapshot; selection = plan.choice; profileVersion = 1; renderContractVersion = 1
        encoding = plan.encoding; writer = plan.writer; gamut = plan.gamut; bitDepth = plan.baseBitDepth
        quality = plan.quality; width = plan.size.width; height = plan.size.height; ceilingStops = plan.peakStops
        self.resolvedAutomatic = resolvedAutomatic; self.resplitReasons = resplitReasons.sorted()
    }
    public func exportKey() throws -> ExportKey {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Includes Recipe, source revision/content, LUT/model/frame content, profile and render contract.
        let data = try encoder.encode(self)
        return ExportKey(rawValue: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
