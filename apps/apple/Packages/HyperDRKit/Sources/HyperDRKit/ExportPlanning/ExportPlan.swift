import Foundation

/// What the open photo is, as far as export planning cares.
public struct ExportSource: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// RAW, developed through `CIRAWFilter`: an HDR rendition.
        case raw
        /// One rendition: JPEG, PNG, TIFF, or a HEIC/AVIF without a gain map.
        case raster
        /// An SDR base plus the photo's own gain map (the `dual` domain).
        case dual
    }

    public let kind: Kind
    /// The oriented size the photo is written at.
    public let pixelSize: ExportPixelSize
    /// The RAW sensor size, when it differs from the developed size.
    public let sensorSize: ExportPixelSize?
    /// The channel count of the photo's own gain map; 1 when it has none.
    public let authoredGainChannels: Int

    public init(kind: Kind, pixelSize: ExportPixelSize, sensorSize: ExportPixelSize? = nil,
                authoredGainChannels: Int = 1) {
        self.kind = kind
        self.pixelSize = pixelSize
        self.sensorSize = sensorSize
        self.authoredGainChannels = authoredGainChannels
    }

    /// RAW and photos that carry their own gain map have highlight information
    /// above SDR white, so an adaptive HEIC pair for them takes a 10-bit base
    /// (M3 contract §5.4).
    public var isHDRRendition: Bool { kind != .raster }
}

/// The edit state the plan needs, and nothing else.
public struct ExportEditFacts: Sendable, Hashable {
    /// The HDR group's switch. Off writes the SDR version: no gain map at all.
    public var hdrEnabled: Bool
    /// The resolved `hdr.range` in stops. "Auto" is resolved before planning:
    /// for `hdr` and `dual` sources it is never below the source's own headroom.
    public var peakStops: Double
    /// A `dual` source whose edit stayed inside the HDR group keeps its own gain
    /// map (p7-adjustments, the 2026-10-21 H1 exception). Anything else makes the
    /// pair a resplit. The default is false on purpose: without proof that the
    /// gain is still a transform of the photo's own map, re-separating is the
    /// answer that is always right.
    public var keepsAuthoredGain: Bool

    public init(hdrEnabled: Bool = true, peakStops: Double, keepsAuthoredGain: Bool = false) {
        self.hdrEnabled = hdrEnabled
        self.peakStops = peakStops
        self.keepsAuthoredGain = keepsAuthoredGain
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
    public var frame: ExportFrameFacts
    public var edit: ExportEditFacts
    /// Only the "Photos" destination reads this; a web or social export ignores it.
    public var library: ExportLibraryFacts
    public var resources: ExportRetainedResources

    public init(choice: ExportChoice, source: ExportSource, frame: ExportFrameFacts = ExportFrameFacts(),
                edit: ExportEditFacts, library: ExportLibraryFacts = ExportLibraryFacts(),
                resources: ExportRetainedResources = ExportRetainedResources()) {
        self.choice = choice
        self.source = source
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
            encoding = format.encoding
            // BT.2100 formats define their own primaries.
            gamut = format.encoding.isBT2100 ? .rec2020 : format.gamut
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
        } else if encoding.writesGainMap {
            baseBitDepth = writesGainMap && request.source.isHDRRendition ? 10 : 8
        } else {
            baseBitDepth = 8
        }

        // An HDR output is a gain-map pair or a BT.2100 file; with the HDR group
        // off the content has no highlights left above SDR white, so it has no peak.
        let outputIsHDR = request.edit.hdrEnabled && (encoding.writesGainMap || encoding.isBT2100)
        let ceiling = profile?.ceilingStops ?? encoding.ceilingStops
        let peakStops = outputIsHDR ? min(request.edit.peakStops, ceiling) : nil
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
                                     degradation: admission.degradation),
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
            if baseBitDepth == 10 {
                // 10-bit base pair: 1.06 GiB against 3.52 GiB at 61 MP.
                (.inHouse, .peakMemory)
            } else {
                // 8-bit base pair: ImageIO gains 1.37/1.80 dB at equal size; a plain
                // 8-bit SDR HEIC has no pair to package, so ImageIO writes it too.
                (.imageIO, writesGainMap ? .qualityAtEqualSize : .noComparison)
            }
        }
    }

    // MARK: Gain map

    static func gainMapPlan(request: ExportPlanRequest, writer: ExportWriter,
                            writesGainMap: Bool) -> GainMapPlan {
        guard writesGainMap else { return .sdr }
        let zeroInFrame = request.frame.isFramed
        guard request.source.kind == .dual else {
            // Everything we separate ourselves is one channel with zero offsets.
            return GainMapPlan(origin: .separated, channels: 1, zeroGainInFrame: zeroInFrame)
        }
        guard request.edit.keepsAuthoredGain else {
            return GainMapPlan(origin: .resplit, channels: 1, zeroGainInFrame: zeroInFrame,
                               resplitReason: .editedBeyondGain)
        }
        let channels = request.source.authoredGainChannels == 3 ? 3 : 1
        if channels == 3, !writer.carriesThreeChannelGain {
            return GainMapPlan(origin: .resplit, channels: 1, zeroGainInFrame: zeroInFrame,
                               resplitReason: .writerCarriesOneChannel)
        }
        return GainMapPlan(origin: .authored, channels: channels, zeroGainInFrame: zeroInFrame)
    }

    // MARK: Memory

    private struct Admission {
        let writer: ExportWriter
        let reason: ExportWriterReason
        let gainMap: GainMapPlan
        let estimate: ExportMemoryEstimate
        let availableBytes: Int?
        let degradation: ExportDegradation?
        let blockers: [ExportBlocker]
    }

    private static func admitMemory(request: ExportPlanRequest,
                                    preferred: (writer: ExportWriter, reason: ExportWriterReason),
                                    photoSize: ExportPixelSize, size: ExportPixelSize,
                                    encoding: ExportEncoding, writesGainMap: Bool,
                                    baseBitDepth: Int,
                                    budget: any ExportMemoryBudget) -> Admission {
        // The preferred writer first; ImageIO's 8-bit pair can fall back to ours
        // when its (much larger) peak does not fit.
        var candidates = [preferred]
        if preferred.writer == .imageIO {
            candidates.append((.inHouse, .memoryFallback))
        }
        func estimate(writer: ExportWriter, rows: Int) -> ExportMemoryEstimate {
            ExportMemoryEstimate.estimate(ExportMemoryEstimate.Input(
                source: request.source, photoSize: photoSize, canvas: size,
                encoding: encoding, writer: writer,
                writesGainMap: writesGainMap, isFramed: request.frame.isFramed,
                baseBitDepth: baseBitDepth, writeRows: rows, retainedBytes: request.resources.bytes))
        }
        let full = candidates.map { ($0, estimate(writer: $0.writer, rows: size.height)) }
        let available = budget.availableBytes()
        guard let available else {
            // The host cannot say: write the preferred way and do not degrade.
            return Admission(writer: preferred.writer, reason: preferred.reason,
                             gainMap: gainMapPlan(request: request, writer: preferred.writer,
                                                  writesGainMap: writesGainMap),
                             estimate: full[0].1, availableBytes: nil, degradation: nil, blockers: [])
        }
        for (index, candidate) in candidates.enumerated() {
            let gainMap = gainMapPlan(request: request, writer: candidate.writer,
                                      writesGainMap: writesGainMap)
            let whole = full[index].1
            if whole.fits(in: available) {
                return Admission(writer: candidate.writer, reason: candidate.reason, gainMap: gainMap,
                                 estimate: whole, availableBytes: available,
                                 degradation: index == 0 ? nil : .switchedWriter(candidate.writer),
                                 blockers: [])
            }
            if candidate.writer.streamsInStrips {
                let rows = ExportMemoryEstimate.stripHeight
                let strips = estimate(writer: candidate.writer, rows: rows)
                if strips.fits(in: available) {
                    return Admission(writer: candidate.writer, reason: candidate.reason, gainMap: gainMap,
                                     estimate: strips, availableBytes: available,
                                     degradation: .strips(rowHeight: rows), blockers: [])
                }
            }
        }
        let shortfall = full[0].1
        return Admission(writer: preferred.writer, reason: preferred.reason,
                         gainMap: gainMapPlan(request: request, writer: preferred.writer,
                                              writesGainMap: writesGainMap),
                         estimate: shortfall, availableBytes: available, degradation: .refused,
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
