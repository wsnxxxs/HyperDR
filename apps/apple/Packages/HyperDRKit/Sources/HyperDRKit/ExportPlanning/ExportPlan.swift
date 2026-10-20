import Foundation
import HyperDRRecipe
import HyperDREngine

/// What the open photo is, as far as export planning cares.
public struct ExportSource: Sendable, Hashable {
    /// The source's input domain, as the Recipe states it (gpu-pipeline §3):
    /// `sdr`, `hdr`, `dual` or `rawEDR`. The domain decides the base depth, and
    /// with it the writer and the memory row, so a caller never has to claim a
    /// RAW or a pair that is not there.
    public let domain: InputDomain
    /// The oriented raster the source decodes to, before any destination limit.
    public let pixelSize: ExportPixelSize
    /// The RAW sensor size, when it differs from the developed size.
    public let sensorSize: ExportPixelSize?

    public init(domain: InputDomain, pixelSize: ExportPixelSize,
                sensorSize: ExportPixelSize? = nil) {
        self.domain = domain
        self.pixelSize = pixelSize
        self.sensorSize = sensorSize
    }

    /// Anything but `sdr` carries real values above SDR white, so an adaptive
    /// HEIC pair for it takes a 10-bit base (M3 contract §5.4).
    public var isHDRRendition: Bool { domain != .sdr }
}

/// The gain-map pair the render produced for this export (gpu-pipeline §3, and
/// p7-adjustments' 2026-10-21 H1 exception). The plan decides the writer and
/// any re-separation from this, never from the source file's channel count: a
/// one-channel authored map can become a three-channel pair once an HDR-only
/// edit is folded into it exactly (`RenderEngine.renderAuthorRegion` reports
/// `gainChannelCount: 3` then).
public struct ExportGainPair: Sendable, Hashable, Codable {
    public enum Provenance: String, Sendable, Hashable, Codable {
        /// The photo's own pair, untouched (Render's `.authored`).
        case authored
        /// The photo's own pair with an HDR-only edit folded into its gain, so
        /// the channel count may have changed (Render's `.authored`).
        case editedAuthored
        /// Separated by us from an HDR rendition or an expansion (Render's `.split`).
        case separated
        /// Re-separated after an edit that changed tone, colour or look
        /// (Render's `.resplit`).
        case resplit
    }

    public let provenance: Provenance
    /// 1 or 3 (ISO 21496-1). Ours are always 1; an authored pair may be 3.
    public let channels: Int
    /// True when the pair's base and alternate offsets are both zero, which is
    /// always true of what we separate and not always of an imported pair.
    public let offsetsAreZero: Bool
    public let offsetsAreEqual: Bool
    public let gainWorkingGamut: String
    public let hasSignedGain: Bool
    public let headroomMatchesGainMaximum: Bool

    public init(provenance: Provenance, channels: Int = 1, offsetsAreZero: Bool = true,
                offsetsAreEqual: Bool? = nil, gainWorkingGamut: String = "display-p3",
                hasSignedGain: Bool = false, headroomMatchesGainMaximum: Bool = true) {
        self.provenance = provenance
        self.channels = channels
        self.offsetsAreZero = offsetsAreZero
        self.offsetsAreEqual = offsetsAreEqual ?? offsetsAreZero
        self.gainWorkingGamut = gainWorkingGamut; self.hasSignedGain = hasSignedGain
        self.headroomMatchesGainMaximum = headroomMatchesGainMaximum
    }

    /// The pair we separate from an `sdr`, `hdr` or `rawEDR` source: one channel,
    /// zero offsets.
    public static let separatedMono = ExportGainPair(provenance: .separated)
}

/// The edit state the plan needs, and nothing else.
public struct ExportEditFacts: Sendable, Hashable {
    /// The HDR group's switch. Off writes the SDR version: no gain map at all.
    public var hdrEnabled: Bool
    /// The resolved `hdr.range` in stops. "Auto" is resolved before planning:
    /// for `hdr` and `dual` sources it is never below the source's own headroom.
    public var peakStops: Double

    public init(hdrEnabled: Bool = true, peakStops: Double) {
        self.hdrEnabled = hdrEnabled
        self.peakStops = peakStops
    }
}

/// A sentence part a view composes. The planning layer never localizes; it
/// names what is said and what fills the placeholders.
public enum ExportMessageArgument: Sendable, Hashable {
    /// Already-formatted text (a number, a byte count).
    case text(String)
    /// Another catalogue key, resolved before it is substituted.
    case key(String)
    /// A stop count, written by `ExportPlanText.stops` ("+2.4").
    case stops(Double)
    /// A pixel count, written by `ExportPlanText.pixels`.
    case pixels(Int)
}

public struct ExportMessage: Sendable, Hashable {
    public let key: String
    public let arguments: [ExportMessageArgument]

    public init(key: String, arguments: [ExportMessageArgument] = []) {
        self.key = key
        self.arguments = arguments
    }
}

/// Something that stops the export; `code` is for logs and tests, `message` for
/// the panel.
public struct ExportBlocker: Sendable, Hashable {
    public let code: String
    public let message: ExportMessage

    public init(code: String, message: ExportMessage) {
        self.code = code
        self.message = message
    }
}

/// The read-only "Will write" row (p7-adjustments §4.1): encoding, gamut, size
/// and peak, as keys with their arguments.
public struct WillWriteSummary: Sendable, Hashable {
    public let labelKey: String
    public let parts: [ExportMessage]

    public init(parts: [ExportMessage]) {
        self.labelKey = "dest.willWrite"
        self.parts = parts
    }
}

/// How the plan's numbers are written. Locale-independent on purpose: the app
/// formats the same values with the user's locale elsewhere, and this is the one
/// place a plan's own sentences (a stop count, a byte count) are spelled out.
public enum ExportPlanText {
    /// "+2.4", "+3": a stop count with its sign, at most one decimal.
    public static func stops(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let digits = rounded == rounded.rounded() ? 0 : 1
        return String(format: "%+.\(digits)f", rounded)
    }

    public static func pixels(_ value: Int) -> String { "\(value)" }

    /// "3.1 GB", "400 MB": decimal units, enough for a sentence.
    public static func bytes(_ value: Int) -> String {
        let gigabytes = Double(value) / 1_000_000_000
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        if value < 1_000_000 { return "< 1 MB" }
        return String(format: "%.0f MB", Double(value) / 1_000_000)
    }
}

/// Everything the plan is computed from. No service, no engine, no AppKit:
/// a value in, a value out.
public struct ExportPlanRequest: Sendable, Hashable {
    public var choice: ExportChoice
    public var source: ExportSource
    /// The pair the render produced, when it produced one. nil is read as "the
    /// render did what our separation always does" for an `sdr`, `hdr` or
    /// `rawEDR` source, and as a resplit for a `dual` one: without a
    /// description, re-separating is the answer that is always right.
    public var pair: ExportGainPair?
    public var frame: ExportFrameFacts
    public var edit: ExportEditFacts
    /// Only the "Photos" destination reads this; a web or social export ignores it.
    public var library: ExportLibraryFacts
    public var resources: ExportRetainedResources

    public init(choice: ExportChoice, source: ExportSource, pair: ExportGainPair? = nil,
                frame: ExportFrameFacts = ExportFrameFacts(),
                edit: ExportEditFacts, library: ExportLibraryFacts = ExportLibraryFacts(),
                resources: ExportRetainedResources = ExportRetainedResources()) {
        self.choice = choice
        self.source = source
        self.pair = pair
        self.frame = frame
        self.edit = edit
        self.library = library
        self.resources = resources
    }
}

/// What the export will write, and why, for one choice of destination or
/// custom format. Shared by the three platforms; P7-3b turns it into a render
/// request and a writer call.
public struct ExportPlan: Sendable, Hashable {
    /// The panel page this plan came from.
    public let choice: ExportChoice
    /// The destination, when the choice was one.
    public let destination: ExportDestination?
    /// The custom format, when the choice was one.
    public let custom: CustomExportFormat?
    public let handling: DestinationHandling?
    public let encoding: ExportEncoding
    /// 8 or 10: an adaptive pair with a 10-bit base for an HDR rendition.
    public let baseBitDepth: Int
    public let writer: ExportWriter
    public let writerReason: ExportWriterReason
    public let gamut: ExportColorGamut
    /// A BT.2100 format defines its own primaries, so the page's gamut control
    /// does not apply to it.
    public let gamutIsFixedByFormat: Bool
    public let quality: Int
    /// The photograph after the destination's long-edge limit: the size it is
    /// graded at, and the size a frame is laid out around.
    public let photoSize: ExportPixelSize
    /// The size actually written: `photoSize`, or the frame's canvas.
    public let size: ExportPixelSize
    /// nil when the original size is kept.
    public let longEdgeLimit: Int?
    /// The HDR ceiling of what is written, in stops (a gain map's, or a BT.2100
    /// file's). nil when the output carries no HDR: an SDR format, or the HDR
    /// group switched off.
    public let peakStops: Double?
    public let gainMap: GainMapPlan
    /// False only for the two publishing destinations.
    public let keepLocation: Bool
    public let memory: ExportMemoryPlan
    /// Only for the "Photos" destination.
    public let library: LibrarySavePlan?
    /// Sentences the panel shows beside the summary (a narrowed peak, a crop
    /// hint). Non-fatal.
    public let notices: [ExportMessage]
    public let blockers: [ExportBlocker]
    public let summary: WillWriteSummary

    public var isExecutable: Bool { blockers.isEmpty }

    /// What "Custom format…" starts from when the user leaves a destination
    /// (p7-adjustments §4.1). The destination's long edge is not carried: the
    /// custom page writes the original size.
    public var customCarryingSettings: CustomExportFormat {
        CustomExportFormat(encoding: encoding, gamut: gamut, quality: quality)
    }
}

/// Turns a request into a plan: format, writer, size, gain map, memory
/// admission and (for Photos) the save mode.
public enum ExportPlanner {
    public static func plan(_ request: ExportPlanRequest,
                            budget: any ExportMemoryBudget = SystemExportMemoryBudget(),
                            preferences: (any ExportPreferenceStore)? = nil) -> ExportPlan {
        let destination = request.choice.destination
        let profile = destination?.profile

        let encoding: ExportEncoding
        let gamut: ExportColorGamut
        let quality: Int
        let longEdge: Int?
        let keepLocation: Bool
        switch request.choice {
        case .destination(let destination):
            let profile = destination.profile
            encoding = request.edit.hdrEnabled ? profile.encoding : profile.sdrEncoding
            gamut = request.edit.hdrEnabled ? profile.gamut : profile.sdrGamut
            quality = profile.quality
            longEdge = profile.longEdge
            keepLocation = profile.keepLocation
        case .custom(let format):
            encoding = !request.edit.hdrEnabled && format.encoding == .isoGainMapJPEG ? .sdrJPEG : format.encoding
            // BT.2100 formats define their own primaries.
            gamut = format.encoding.isBT2100 ? .rec2020
                : format.encoding.writesGainMap ? .p3
                : format.gamut == .rec2020 ? .p3 : format.gamut
            quality = min(max(format.quality, 0), 100)
            // The custom page has no size control: it writes the original size.
            longEdge = nil
            keepLocation = true
        }

        // A destination's long edge limits the photograph. A frame is laid out
        // around that size by its caller, so its canvas is written as given.
        let photoSize = ExportPlanner.photoSize(for: request.choice, photo: request.source.pixelSize)
        let size = request.frame.canvas ?? photoSize
        let writesGainMap = encoding.writesGainMap && request.edit.hdrEnabled
        let baseBitDepth: Int
        if encoding.isBT2100 {
            baseBitDepth = 10
        } else if encoding == .adaptive {
            baseBitDepth = writesGainMap && request.source.isHDRRendition ? 10 : 8
        } else {
            baseBitDepth = encoding == .sdrTIFF ? 16 : 8
        }

        // An HDR output is a gain-map pair or a BT.2100 file; with the HDR group
        // off the content has no highlights left above SDR white, so it has no peak.
        let outputIsHDR = request.edit.hdrEnabled && (encoding.writesGainMap || encoding.isBT2100)
        let ceiling = profile?.ceilingStops ?? encoding.ceilingStops
        // Render accepts range controls from 0.5 stops; an automatic flat
        // source can naturally resolve below that. This floor only limits the
        // requested ceiling and never raises the rendered source's gain.
        let peakStops = outputIsHDR ? max(0.5, min(request.edit.peakStops, ceiling)) : nil
        var notices: [ExportMessage] = []
        if peakStops != nil, request.edit.peakStops > ceiling {
            let stops = ExportMessageArgument.stops(ceiling)
            notices.append(destination == nil
                ? ExportMessage(key: "export.rangeClamped %@ %@",
                                arguments: [.key(encoding.labelKey), stops])
                : ExportMessage(key: "dest.ceiling %@", arguments: [stops]))
        }
        // Instagram crops outside 4:5 … 1.91:1. P7 has no crop tool, so the
        // summary says so and nothing is cut (p7-adjustments §4.2).
        if destination == .social {
            let aspect = Double(size.width) / Double(size.height)
            if aspect < 0.8 - 1e-9 || aspect > 1.91 + 1e-9 {
                notices.append(ExportMessage(key: "dest.social.aspect"))
            }
        }

        let preferred = preferredWriter(encoding: encoding, writesGainMap: writesGainMap,
                                        baseBitDepth: baseBitDepth)
        // Admission prices what is written, so the canvas is the size after the
        // destination's long-edge limit.
        let admission = admitMemory(request: request, preferred: preferred,
                                    photoSize: photoSize, size: size,
                                    encoding: encoding, writesGainMap: writesGainMap,
                                    baseBitDepth: baseBitDepth, budget: budget)
        var blockers = admission.blockers
        if let pair = request.pair, ![1, 3].contains(pair.channels) {
            blockers.append(.init(code: "unsupported_format", message: .init(key: "err.server.unsupported_format")))
        }

        var library: LibrarySavePlan?
        if destination == .photos {
            let savePlan = LibrarySavePlan.plan(
                facts: request.library, isFramed: request.frame.isFramed,
                remembered: preferences?.lastLibrarySaveMode())
            library = savePlan
            if savePlan.selected == nil {
                blockers.append(ExportBlocker(code: "photos_permission_denied",
                    message: ExportMessage(key: "dest.photos.permission")))
            }
        }

        return ExportPlan(
            choice: request.choice,
            destination: destination,
            custom: request.choice.customFormat,
            handling: profile?.handling ?? .file,
            encoding: encoding,
            baseBitDepth: baseBitDepth,
            writer: admission.writer,
            writerReason: admission.reason,
            gamut: gamut,
            gamutIsFixedByFormat: encoding.isBT2100,
            quality: quality,
            photoSize: photoSize,
            size: size,
            longEdgeLimit: longEdge,
            peakStops: peakStops,
            gainMap: admission.gainMap,
            keepLocation: keepLocation,
            memory: ExportMemoryPlan(estimate: admission.estimate,
                                     availableBytes: admission.availableBytes,
                                     degradation: admission.degradation, renderRows: admission.renderRows),
            library: library,
            notices: notices,
            blockers: blockers,
            summary: summary(encoding: encoding, gamut: gamut, size: size, photoSize: photoSize,
                             sourceSize: request.source.pixelSize, peakStops: peakStops))
    }

    /// The photograph's written size for a choice: a destination's long edge,
    /// never upscaling. A frame is laid out around this size.
    public static func photoSize(for choice: ExportChoice, photo: ExportPixelSize) -> ExportPixelSize {
        photo.fitted(longEdge: choice.destination?.profile.longEdge)
    }

    /// Lay out the card around the destination-limited photo before the UI
    /// renders its caption. Pass that frozen layout to Render's FrameSnapshot.
    public static func frameLayout(frame: [String: JSONValue], choice: ExportChoice,
                                   photo: ExportPixelSize) throws -> FrameLayout {
        let size = photoSize(for: choice, photo: photo)
        return try Engine.frameLayout(frame: frame, photoWidth: size.width, photoHeight: size.height)
    }

    // MARK: Writer

    /// gpu-pipeline §11.x, one row per encoding.
    static func preferredWriter(encoding: ExportEncoding, writesGainMap: Bool,
                                baseBitDepth: Int) -> (writer: ExportWriter, reason: ExportWriterReason) {
        switch encoding {
        case .isoGainMapJPEG:
            // Same container, same writer: 1.67/1.55 dB at equal size and 1.21 GiB
            // against 3.11 GiB of peak at 61 MP.
            (.inHouse, .qualityAtEqualSize)
        case .pq, .hlg:
            // 10-bit HEIC: ImageIO's edge is negligible or nil, our peak is a fraction.
            (.inHouse, .peakMemory)
        case .avifPq, .avifHlg:
            (.libavif, .onlyEncoder)
        case .sdrJPEG, .sdrTIFF:
            (.inHouse, .noComparison)
        case .adaptive:
            writesGainMap ? (.inHouse, .peakMemory) : (.imageIO, .noComparison)
        }
    }

    // MARK: Gain map

    static func gainMapPlan(request: ExportPlanRequest, writer: ExportWriter,
                            writesGainMap: Bool) -> GainMapPlan {
        guard writesGainMap else { return .sdr }
        // Without a description, a dual source is planned as a resplit (correct
        // pixels, and it is what Render does once tone, colour or look changed).
        let pair = request.pair
            ?? (request.source.domain == .dual ? ExportGainPair(provenance: .resplit) : .separatedMono)
        let zeroInFrame = request.frame.isFramed
        let authored = pair.provenance == .authored || pair.provenance == .editedAuthored
        let encoding = request.choice.customFormat?.encoding ?? request.choice.destination!.profile.encoding
        let caps = writer.capabilities(encoding: encoding, bitDepth: 8, gainChannels: pair.channels)
        let reason: ResplitReason?
        if pair.gainWorkingGamut != "display-p3" { reason = .unsupportedGainWorkingGamut }
        else if request.frame.isFramed && !pair.offsetsAreEqual { reason = .frameRequiresNeutralPair }
        else if pair.channels == 3 && !caps.supportsThreeChannelGain { reason = .writerCarriesOneChannel }
        else if pair.hasSignedGain && !caps.supportsSignedGain { reason = .writerCannotRepresentSignedGain }
        else if caps.requiresGainMaximumHeadroom && !pair.headroomMatchesGainMaximum { reason = .writerHeadroomContract }
        else { reason = nil }
        if let reason {
            return GainMapPlan(origin: .resplit, channels: 1, offsetsAreZero: true,
                               zeroGainInFrame: zeroInFrame, resplitReason: reason)
        }
        let origin: GainMapPlan.Origin = authored
            ? .authored : pair.provenance == .separated ? .separated : .resplit
        return GainMapPlan(origin: origin, channels: pair.channels,
                           offsetsAreZero: pair.offsetsAreZero,
                           zeroGainInFrame: zeroInFrame)
    }

    // MARK: Memory

    private struct Admission {
        let writer: ExportWriter
        let reason: ExportWriterReason
        let gainMap: GainMapPlan
        let estimate: ExportMemoryEstimate
        let availableBytes: Int?
        let degradation: ExportDegradation?
        let renderRows: Int
        let blockers: [ExportBlocker]
    }

    private static func admitMemory(request: ExportPlanRequest,
                                    preferred: (writer: ExportWriter, reason: ExportWriterReason),
                                    photoSize: ExportPixelSize, size: ExportPixelSize,
                                    encoding: ExportEncoding, writesGainMap: Bool,
                                    baseBitDepth: Int,
                                    budget: any ExportMemoryBudget) -> Admission {
        func estimate(rows: Int) -> ExportMemoryEstimate {
            ExportMemoryEstimate.estimate(ExportMemoryEstimate.Input(
                source: request.source, photoSize: photoSize, canvas: size,
                encoding: encoding, writer: preferred.writer,
                writesGainMap: writesGainMap, isFramed: request.frame.isFramed,
                baseBitDepth: baseBitDepth, writeRows: rows, retainedBytes: request.resources.bytes))
        }
        let available = budget.availableBytes() ?? 256 * 1024 * 1024
        let gainMap = gainMapPlan(request: request, writer: preferred.writer, writesGainMap: writesGainMap)
        for rows in [256, 128, 64] {
            let peak = estimate(rows: rows)
            if peak.fits(in: available) {
                return Admission(writer: preferred.writer, reason: preferred.reason, gainMap: gainMap,
                                 estimate: peak, availableBytes: available,
                                 degradation: rows == 256 ? nil : .renderRows(rowHeight: rows),
                                 renderRows: rows, blockers: [])
            }
        }
        let shortfall = estimate(rows: 64)
        return Admission(writer: preferred.writer, reason: preferred.reason, gainMap: gainMap,
                         estimate: shortfall, availableBytes: available, degradation: .refused, renderRows: 64,
                         blockers: [ExportBlocker(code: "export_memory_exceeded",
                             message: ExportMessage(key: "dest.memoryExceeded %@ %@",
                                 arguments: [.text(ExportPlanText.bytes(shortfall.peak)),
                                             .text(ExportPlanText.bytes(available))]))])
    }

    // MARK: Summary

    private static func summary(encoding: ExportEncoding, gamut: ExportColorGamut,
                                size: ExportPixelSize, photoSize: ExportPixelSize,
                                sourceSize: ExportPixelSize,
                                peakStops: Double?) -> WillWriteSummary {
        var parts = [ExportMessage(key: encoding.labelKey),
                     ExportMessage(key: gamut.labelKey)]
        // "Original size" only when the written picture is the photo as it came.
        parts.append(size == sourceSize && photoSize == sourceSize
            ? ExportMessage(key: "plan.size.original")
            : ExportMessage(key: "plan.size.pixels",
                            arguments: [.pixels(size.width), .pixels(size.height)]))
        if let peakStops {
            parts.append(ExportMessage(key: "plan.peak %@", arguments: [.stops(peakStops)]))
        }
        return WillWriteSummary(parts: parts)
    }
}
