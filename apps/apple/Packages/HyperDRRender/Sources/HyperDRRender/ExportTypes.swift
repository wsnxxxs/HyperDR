import Foundation
import HyperDRRecipe

/// Export pixel coordinates: integral, top-down, after source orientation.
public struct ExportRect: Hashable, Sendable {
    public let x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Destination gamut. Float32 planes remain linear Display P3 for C ABI 4;
/// the writer performs the declared output transfer and gamut conversion.
public enum ExportGamut: String, Hashable, Sendable {
    case displayP3, sRGB, rec2020
}

/// Gaussian print shadow, in final canvas pixels (not fractions of a reference edge).
public struct FrameShadow: Hashable, Sendable {
    public let opacity: Float
    public let sigma: Float
    public let offset: SIMD2<Float>
    public init(opacity: Float = 0, sigma: Float = 0, offset: SIMD2<Float> = .zero) {
        self.opacity = opacity; self.sigma = sigma; self.offset = offset
    }
}

/// Frozen Display P3 straight-alpha PNG. Its native dimensions must equal rect's.
/// No font, SwiftUI view or platform image object crosses the Render boundary.
public struct FrameCaption: Hashable, Sendable {
    public let png: Data
    public let rect: ExportRect
    public init(png: Data, rect: ExportRect) { self.png = png; self.rect = rect }
}

/// Layout already computed by frame_layout for the destination's photo size.
/// Paper is LINEAR Display P3, SDR white=1; convert UI hex/sRGB transfer first.
public struct FrameSnapshot: Hashable, Sendable {
    public let canvasSize: PixelSize
    public let photo: ExportRect
    public let paper: SIMD3<Float>
    public let shadow: FrameShadow
    public let caption: FrameCaption?
    public init(canvasSize: PixelSize, photo: ExportRect, paper: SIMD3<Float>,
                shadow: FrameShadow = FrameShadow(), caption: FrameCaption? = nil) {
        self.canvasSize = canvasSize; self.photo = photo; self.paper = paper
        self.shadow = shadow; self.caption = caption
    }
}

/// Facts about this particular writer/format/depth, not a blanket "in-house" flag.
/// Base is always P3; a non-P3 gain working space requires exact HDR reconstruction
/// and re-separation for C ABI 4, regardless of the selected destination gamut.
public struct ExportPairCapabilities: Hashable, Sendable {
    public let supportsThreeChannelGain: Bool
    public let supportsNonzeroOffsets: Bool
    public let supportsSignedGain: Bool
    /// Apple Adaptive declares alternate headroom as its largest representable gain.
    public let requiresGainMaximumHeadroom: Bool
    public init(supportsThreeChannelGain: Bool, supportsNonzeroOffsets: Bool = true,
                supportsSignedGain: Bool = true, requiresGainMaximumHeadroom: Bool = false) {
        self.supportsThreeChannelGain = supportsThreeChannelGain
        self.supportsNonzeroOffsets = supportsNonzeroOffsets
        self.supportsSignedGain = supportsSignedGain
        self.requiresGainMaximumHeadroom = requiresGainMaximumHeadroom
    }
}

/// Export-only constraints; never mutate the editor's Recipe or persist a bypass.
/// photoSize is before the frame. Nil ceiling keeps the Recipe's resolved range;
/// a non-nil ceiling can only narrow it, using the same HDR soft shoulder.
public struct ExportRenderRequest: Hashable, Sendable {
    public let photoSize: PixelSize
    public let ceilingStops: Float?
    public let gamut: ExportGamut
    public let includesGain: Bool
    public let capabilities: ExportPairCapabilities
    public let frame: FrameSnapshot?
    public init(photoSize: PixelSize, ceilingStops: Float? = nil, gamut: ExportGamut = .displayP3,
                includesGain: Bool = true, capabilities: ExportPairCapabilities,
                frame: FrameSnapshot? = nil) {
        self.photoSize = photoSize; self.ceilingStops = ceilingStops; self.gamut = gamut
        self.includesGain = includesGain; self.capabilities = capabilities; self.frame = frame
    }
    public var canvasSize: PixelSize { frame?.canvasSize ?? photoSize }
}

public enum ExportResplitReason: String, Hashable, Sendable {
    case writerCarriesOneChannel
    case unsupportedGainWorkingGamut
    case writerCannotRepresentOffsets
    case writerCannotRepresentSignedGain
    case writerHeadroomContract
    case frameRequiresNeutralPair
}

/// Decoded log2 gain; offsets are linear SDR-white-relative values, headrooms stops.
/// All exported pairs use the base's linear Display P3 working gamut.
public struct ExportGainMetadata: Equatable, Sendable {
    public let channelCount: Int
    public let baseOffset, alternateOffset: SIMD3<Float>
    public let baseHeadroom, alternateHeadroom: Float
    public init(channelCount: Int, baseOffset: SIMD3<Float> = .zero, alternateOffset: SIMD3<Float> = .zero,
                baseHeadroom: Float = 0, alternateHeadroom: Float) {
        self.channelCount = channelCount; self.baseOffset = baseOffset; self.alternateOffset = alternateOffset
        self.baseHeadroom = baseHeadroom; self.alternateHeadroom = alternateHeadroom
    }
}

/// Owned, tightly packed CPU float32 arrays, top-down. Size is rect.width*rect.height;
/// baseRGB has three samples per pixel; gain has metadata.channelCount, or is empty
/// when includesGain=false. Neither array borrows Metal storage or callback memory.
public struct ExportStripe: Sendable {
    public let rect: ExportRect
    public let baseRGB: [Float]
    public let gain: [Float]
    public init(rect: ExportRect, baseRGB: [Float], gain: [Float]) {
        self.rect = rect; self.baseRGB = baseRGB; self.gain = gain
    }
}

/// Identical for all stripes in an export. Ready before consume receives any pixels.
/// On failure, previously delivered stripes are partial and must be discarded.
public struct ExportRenderReport: Sendable {
    public let canvasSize: PixelSize
    public let gain: ExportGainMetadata?
    public let provenance: PairProvenance
    public let resplitReasons: Set<ExportResplitReason>
    public let resolvedAutomatic: [String:Double]
    /// C ABI presentation_frame; only gain-map formats use framePhoto for E5 readback.
    public let presentationFrame: Bool
    public let framePhoto: ExportRect?
    public init(canvasSize: PixelSize, gain: ExportGainMetadata?, provenance: PairProvenance,
                resplitReasons: Set<ExportResplitReason>, resolvedAutomatic: [String:Double],
                presentationFrame: Bool, framePhoto: ExportRect?) {
        self.canvasSize = canvasSize; self.gain = gain; self.provenance = provenance
        self.resplitReasons = resplitReasons; self.resolvedAutomatic = resolvedAutomatic
        self.presentationFrame = presentationFrame; self.framePhoto = framePhoto
    }
}

/// The single export operation used by Kit and its Fake. RenderEngine conformance
/// follows in b-R's implementation commit. No file I/O/encoding belongs here.
public protocol ExportStripeRendering: Sendable {
    /// One stripe in flight; synchronous consumption provides backpressure.
    /// prepare runs once before consume, so Kit can allocate plane owners or open
    /// an incremental writer using the final channel count and metadata.
    /// Caller awaits AI first; a missing required prediction fails before prepare.
    func renderExportStripes(_ source: RenderSource, recipe: Recipe, lut: ColorLUT?,
                             modelGain: ModelGainPrediction?, request: ExportRenderRequest, rows: Int,
                             prepare: @Sendable (ExportRenderReport) throws -> Void,
                             consume: @Sendable (ExportStripe) throws -> Void) async throws -> ExportRenderReport
}
