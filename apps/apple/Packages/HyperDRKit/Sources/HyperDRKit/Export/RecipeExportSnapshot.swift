import CryptoKit
import Foundation
import HyperDRRecipe
import HyperDRRender

/// Frozen editing intent. Paths, preview bypasses and display headroom are excluded.
public struct RecipeExportSnapshot: Sendable, Codable, Equatable {
    public static let currentVersion = 2
    public let version: Int
    public let recipe: Recipe
    public let source: RecipeSourceRevision
    /// Recipe's model choice, resolved by the service when AI is needed.
    public var modelSelection: String? { recipe.conditionValue("hdr.model")?.stringValue }
    /// Optional exact identity required when re-rendering a historical export.
    public let expectedModelIdentity: String?
    public let frame: RecipeFrameSnapshot?
    public var lutContentHash: String? { recipe.look?.contentHash }

    public init(recipe: Recipe, source: RecipeSourceRevision, expectedModelIdentity: String? = nil,
                frame: FrameSnapshot? = nil) {
        version = Self.currentVersion; self.recipe = recipe; self.source = source
        self.expectedModelIdentity = expectedModelIdentity; self.frame = frame.map(RecipeFrameSnapshot.init)
    }
}

/// Capture when the editor opens the source, not when export starts.
public struct RecipeSourceRevision: Sendable, Codable, Equatable {
    public let sha256: String
    public let byteCount: Int64
    public let modificationTimeMilliseconds: Int64
    public var modificationDate: Date { Date(timeIntervalSince1970: Double(modificationTimeMilliseconds) / 1000) }
    public init(sha256: String, byteCount: Int64, modificationDate: Date) {
        self.sha256 = sha256; self.byteCount = byteCount; self.modificationTimeMilliseconds = Int64((modificationDate.timeIntervalSince1970 * 1000).rounded())
    }
    public init(session: PhotoSession) throws {
        let values = try session.sourceURL.resourceValues(forKeys: [.contentModificationDateKey])
        self.init(sha256: session.sha256, byteCount: session.byteCount,
                  modificationDate: values.contentModificationDate ?? .distantPast)
    }
}

/// Codable frame geometry and caption content identity; PNG bytes are leased separately.
public struct RecipeFrameSnapshot: Sendable, Codable, Equatable {
    public let width, height: Int
    public let photo: [Int]
    public let paper: SIMD3<Float>
    public let shadowOpacity, shadowSigma: Float
    public let shadowOffset: SIMD2<Float>
    /// Transient bytes; the serialized snapshot carries only the content hash.
    public internal(set) var captionPNG: Data? = nil
    public let captionSHA256: String?
    public let captionRect: [Int]?
    public init(_ frame: FrameSnapshot) {
        width = frame.canvasSize.width; height = frame.canvasSize.height
        photo = [frame.photo.x, frame.photo.y, frame.photo.width, frame.photo.height]
        paper = frame.paper; shadowOpacity = frame.shadow.opacity; shadowSigma = frame.shadow.sigma
        shadowOffset = frame.shadow.offset; captionPNG = frame.caption?.png
        captionSHA256 = frame.caption.map { SHA256.hash(data: $0.png).map { String(format: "%02x", $0) }.joined() }
        captionRect = frame.caption.map { [$0.rect.x, $0.rect.y, $0.rect.width, $0.rect.height] }
    }
    private enum CodingKeys: String, CodingKey {
        case width, height, photo, paper, shadowOpacity, shadowSigma, shadowOffset, captionSHA256, captionRect
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.width == b.width && a.height == b.height && a.photo == b.photo && a.paper == b.paper
            && a.shadowOpacity == b.shadowOpacity && a.shadowSigma == b.shadowSigma
            && a.shadowOffset == b.shadowOffset && a.captionSHA256 == b.captionSHA256 && a.captionRect == b.captionRect
    }
    public func renderFrame() throws -> FrameSnapshot {
        guard width > 0, height > 0, width <= 1_048_576, height <= 1_048_576,
              width <= (1 << 34) / height, photo.count == 4,
              (captionSHA256 == nil || captionPNG != nil),
              captionRect == nil || captionRect?.count == 4 else {
            throw RecipeExportError.invalidSnapshot
        }
        func rect(_ a: [Int]) -> ExportRect { .init(x: a[0], y: a[1], width: a[2], height: a[3]) }
        guard photo[0] >= 0, photo[1] >= 0, photo[2] > 0, photo[3] > 0,
              photo[0] <= width - photo[2], photo[1] <= height - photo[3],
              photo[0].isMultiple(of: 2), photo[1].isMultiple(of: 2),
              paper.x.isFinite, paper.y.isFinite, paper.z.isFinite,
              (0...1).contains(paper.x), (0...1).contains(paper.y), (0...1).contains(paper.z),
              shadowOpacity.isFinite, (0...1).contains(shadowOpacity),
              shadowSigma.isFinite, shadowSigma >= 0, shadowOffset.x.isFinite, shadowOffset.y.isFinite,
              (captionSHA256 == nil) == (captionRect == nil) else { throw RecipeExportError.invalidSnapshot }
        if let c = captionRect {
            guard c[0] >= 0, c[1] >= 0, c[2] > 0, c[3] > 0, c[0] <= width - c[2], c[1] <= height - c[3] else {
                throw RecipeExportError.invalidSnapshot
            }
        }
        let caption = captionPNG.flatMap { png in captionRect.map { FrameCaption(png: png, rect: rect($0)) } }
        return FrameSnapshot(canvasSize: .init(width: width, height: height), photo: rect(photo), paper: paper,
                             shadow: .init(opacity: shadowOpacity, sigma: shadowSigma, offset: shadowOffset), caption: caption)
    }
}

/// The actual output contract, frozen separately from editable intent.
public struct ResolvedExportSnapshot: Sendable, Codable, Equatable {
    public let snapshot: RecipeExportSnapshot
    public let modelIdentity: String?
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
    public let gain: ResolvedExportGain?
    /// Pair origin before export adaptation resplits.
    public let sourceProvenance: String?
    /// Pair origin after export adaptation.
    public let provenance: String?
    /// Resolved Recipe range before/after Render's output ceiling, in stops.
    public let rangeBeforeCeiling, rangeAfterCeiling: Float?
    public init(snapshot: RecipeExportSnapshot, plan: ExportPlan, modelIdentity: String? = nil,
                resolvedAutomatic: [String: Double] = [:], resplitReasons: [String] = [],
                report: ExportRenderReport? = nil) {
        self.modelIdentity = modelIdentity
        self.snapshot = snapshot; selection = plan.choice; profileVersion = plan.destination?.profile.version ?? 1; renderContractVersion = 1
        encoding = plan.encoding; writer = plan.writer; gamut = plan.gamut; bitDepth = plan.baseBitDepth
        quality = plan.quality; width = plan.size.width; height = plan.size.height; ceilingStops = plan.peakStops
        self.resolvedAutomatic = resolvedAutomatic; self.resplitReasons = resplitReasons.sorted()
        gain = report?.gain.map(ResolvedExportGain.init)
        sourceProvenance = report?.sourceProvenance.rawValue
        provenance = report?.provenance.rawValue
        rangeBeforeCeiling = report?.rangeBeforeCeiling
        rangeAfterCeiling = report?.rangeAfterCeiling
    }
    public func exportKey() throws -> ExportKey {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var recipe = snapshot.recipe
        if let look = recipe.look { recipe.look = .init(contentHash: look.contentHash, name: "") }
        struct Identity: Encodable {
            let recipe: Recipe
            let sourceSHA256: String
            let modelIdentity: String?
            let frame: RecipeFrameSnapshot?
            let selection: ExportChoice
            let profileVersion, renderContractVersion: Int
            let encoding: ExportEncoding
            let writer: ExportWriter
            let gamut: ExportColorGamut
            let bitDepth, quality, width, height: Int
            let ceilingStops: Double?
            let resolvedAutomatic: [String: Double]
            let resplitReasons: [String]
            let gain: ResolvedExportGain?
        }
        let key = Identity(recipe: recipe, sourceSHA256: snapshot.source.sha256, modelIdentity: modelIdentity,
                           frame: snapshot.frame, selection: selection, profileVersion: profileVersion,
                           renderContractVersion: renderContractVersion, encoding: encoding, writer: writer,
                           gamut: gamut, bitDepth: bitDepth, quality: quality, width: width, height: height,
                           ceilingStops: ceilingStops, resolvedAutomatic: resolvedAutomatic,
                           resplitReasons: resplitReasons, gain: gain)
        return ExportKey(rawValue: SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined())
    }
}

public struct ResolvedExportGain: Sendable, Codable, Equatable {
    public let channels: Int
    public let baseOffset, alternateOffset: SIMD3<Float>
    public let baseHeadroom, alternateHeadroom: Float
    public init(_ gain: ExportGainMetadata) {
        channels = gain.channelCount; baseOffset = gain.baseOffset; alternateOffset = gain.alternateOffset
        baseHeadroom = gain.baseHeadroom; alternateHeadroom = gain.alternateHeadroom
    }
}
