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
    public let hasAlpha: Bool

    public init(domain: InputDomain, pixelSize: ExportPixelSize,
                sensorSize: ExportPixelSize? = nil, hasAlpha: Bool = false) {
        self.domain = domain
        self.pixelSize = pixelSize
        self.sensorSize = sensorSize
        self.hasAlpha = hasAlpha
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
    /// ISO base headroom in log2 stops; the manual ImageIO writer requires SDR (zero).
    public let baseHeadroom: Double
    public let headroomMatchesGainMaximum: Bool

    public init(provenance: Provenance, channels: Int = 1, offsetsAreZero: Bool = true,
                offsetsAreEqual: Bool? = nil, gainWorkingGamut: String = "display-p3",
                hasSignedGain: Bool = false, headroomMatchesGainMaximum: Bool = true,
                baseHeadroom: Double = 0) {
        self.provenance = provenance
        self.channels = channels
        self.offsetsAreZero = offsetsAreZero
        self.offsetsAreEqual = offsetsAreEqual ?? offsetsAreZero
        self.gainWorkingGamut = gainWorkingGamut; self.hasSignedGain = hasSignedGain
        self.baseHeadroom = baseHeadroom
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
    /// Renderer/host capability; false also provides a whole-plane parity baseline.
    public var capabilities: ExportEncodingCapabilities
    public var allowsRowInput: Bool

    public init(choice: ExportChoice, source: ExportSource, pair: ExportGainPair? = nil,
                frame: ExportFrameFacts = ExportFrameFacts(),
                edit: ExportEditFacts, library: ExportLibraryFacts = ExportLibraryFacts(),
                resources: ExportRetainedResources = ExportRetainedResources(), allowsRowInput: Bool = true,
                capabilities: ExportEncodingCapabilities = .init()) {
        self.choice = choice
        self.source = source
        self.pair = pair
        self.frame = frame
        self.edit = edit
        self.library = library
        self.resources = resources
        self.allowsRowInput = allowsRowInput
        self.capabilities = capabilities
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
    public let notices: [ExportNotice]
    public let blockers: [ExportBlockReason]

    public var isExecutable: Bool { blockers.isEmpty }

    /// What "Custom format…" starts from when the user leaves a destination
    /// (p7-adjustments §4.1), including its photograph long-edge limit.
    public var customCarryingSettings: CustomExportFormat {
        CustomExportFormat(encoding: encoding, gamut: gamut, quality: quality, longEdge: longEdgeLimit)
    }
}

/// Turns a request into a plan: format, writer, size, gain map, memory
/// admission and (for Photos) the save mode.
public enum ExportPlanner {
    public static func plan(_ request: ExportPlanRequest,
                            budget: any ExportMemoryBudget = SystemExportMemoryBudget(),
                            preferences: (any ExportPreferenceStore)? = nil) -> ExportPlan {
        makePlan(request, budget: budget, preferences: preferences, suggestSize: true)
    }

    private static func makePlan(_ request: ExportPlanRequest, budget: any ExportMemoryBudget,
                                 preferences: (any ExportPreferenceStore)?, suggestSize: Bool) -> ExportPlan {
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
            longEdge = format.longEdge
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
        var notices: [ExportNotice] = []
        let selectedEncoding = request.choice.customFormat?.encoding ?? profile!.encoding
        if !request.edit.hdrEnabled && selectedEncoding.writesGainMap {
            notices.append(.sdrVersion)
        }
        if peakStops != nil, request.edit.peakStops > ceiling {
            notices.append(.ceiling(stops: ceiling, scope: destination.map { .destination($0) } ?? .format(encoding)))
        }
        // Instagram crops outside 4:5 … 1.91:1. P7 has no crop tool, so the
        // summary says so and nothing is cut (p7-adjustments §4.2).
        if destination == .social {
            let aspect = Double(size.width) / Double(size.height)
            if aspect < 0.8 - 1e-9 || aspect > 1.91 + 1e-9 {
                notices.append(.socialAspect)
            }
        }

        var preferred = preferredWriter(encoding: encoding, writesGainMap: writesGainMap,
                                        baseBitDepth: baseBitDepth)
        if preferred.writer == .imageIO && writesGainMap && (request.pair?.baseHeadroom ?? 0) != 0 {
            preferred = (.inHouse, .unsupportedCapability)
        }
        if request.frame.isFramed && encoding == .adaptive && writesGainMap && baseBitDepth == 8 {
            preferred = (.inHouse, .frameGainProtection)
        }
        // Admission prices what is written, so the canvas is the size after the
        // destination's long-edge limit.
        let admission = admitMemory(request: request, preferred: preferred,
                                    photoSize: photoSize, size: size,
                                    encoding: encoding, writesGainMap: writesGainMap,
                                    baseBitDepth: baseBitDepth, budget: budget)
        var blockers = admission.blockers
        if request.source.hasAlpha { notices.append(.alphaOnBlack) }
        if let reason = availability(of: selectedEncoding, source: request.source, capabilities: request.capabilities, edit: request.edit) {
            blockers.append(reason)
        }
        let maxLongEdge = suggestSize && !admission.estimate.fits(in: admission.availableBytes ?? 0)
            ? maximumLongEdge(request, budget: admission.availableBytes ?? 0, upper: photoSize.longEdge) : nil
        blockers = blockers.map { reason in
            if case .memory(let needed, let available, let size, _) = reason {
                return .memory(needed: needed, available: available, size: size, maxLongEdge: maxLongEdge)
            }
            return reason
        }
        if let pair = request.pair, ![1, 3].contains(pair.channels) {
            blockers.append(.unsupportedPair)
        }

        var library: LibrarySavePlan?
        if destination == .photos {
            let savePlan = LibrarySavePlan.plan(
                facts: request.library, isFramed: request.frame.isFramed,
                remembered: preferences?.lastLibrarySaveMode())
            library = savePlan
            if savePlan.selected == nil {
                blockers.append(.photosNotAvailable(savePlan.options.compactMap(\.unavailableReason).first ?? .notVerified))
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
                                     degradation: admission.degradation, renderRows: admission.renderRows,
                usesRowInput: request.allowsRowInput && admission.writer.supportsRowInput(encoding: encoding),
                maxAdmissibleLongEdge: maxLongEdge),
            library: library,
            notices: notices,
            blockers: blockers)
    }

    /// The photograph's written size for a choice: a destination's long edge,
    /// never upscaling. A frame is laid out around this size.
    public static func photoSize(for choice: ExportChoice, photo: ExportPixelSize) -> ExportPixelSize {
        photo.fitted(longEdge: choice.customFormat?.longEdge ?? choice.destination?.profile.longEdge)
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
            writesGainMap ? (baseBitDepth == 8 ? (.imageIO, .qualityAtEqualSize) : (.inHouse, .peakMemory)) : (.imageIO, .noComparison)
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
        else if caps.requiresGainMaximumHeadroom && (!pair.headroomMatchesGainMaximum || pair.baseHeadroom != 0) { reason = .writerHeadroomContract }
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
        let blockers: [ExportBlockReason]
    }

    private static func admitMemory(request: ExportPlanRequest,
                                    preferred: (writer: ExportWriter, reason: ExportWriterReason),
                                    photoSize: ExportPixelSize, size: ExportPixelSize,
                                    encoding: ExportEncoding, writesGainMap: Bool,
                                    baseBitDepth: Int,
                                    budget: any ExportMemoryBudget) -> Admission {
        func estimate(writer: ExportWriter, rows: Int) -> ExportMemoryEstimate {
            ExportMemoryEstimate.estimate(ExportMemoryEstimate.Input(
                source: request.source, photoSize: photoSize, canvas: size,
                encoding: encoding, writer: writer,
                writesGainMap: writesGainMap, isFramed: request.frame.isFramed,
                baseBitDepth: baseBitDepth, writeRows: rows, retainedBytes: request.resources.bytes,
                allowsRowInput: request.allowsRowInput,
                quality: request.choice.customFormat?.quality ?? request.choice.destination!.profile.quality))
        }
        let available = budget.availableBytes() ?? 256 * 1024 * 1024
        let canFallback = preferred.writer == .imageIO && encoding == .adaptive && writesGainMap && baseBitDepth == 8
        let writers: [ExportWriter] = canFallback ? [preferred.writer, .inHouse] : [preferred.writer]
        for rows in [256, 128, 64] {
            for writer in writers {
                let peak = estimate(writer: writer, rows: rows)
                if peak.fits(in: available) {
                    let fallback = writer != preferred.writer
                    return Admission(writer: writer, reason: fallback ? .memoryFallback : preferred.reason,
                        gainMap: gainMapPlan(request: request, writer: writer, writesGainMap: writesGainMap),
                        estimate: peak, availableBytes: available,
                        degradation: fallback ? .switchedWriter(writer) : rows == 256 ? nil : .renderRows(rowHeight: rows),
                        renderRows: rows, blockers: [])
                }
            }
        }
        let gainMap = gainMapPlan(request: request, writer: preferred.writer, writesGainMap: writesGainMap)
        let shortfall = writers.map { estimate(writer: $0, rows: 64) }.min { $0.peak < $1.peak }!
        return Admission(writer: preferred.writer, reason: preferred.reason, gainMap: gainMap,
                         estimate: shortfall, availableBytes: available, degradation: .refused, renderRows: 64,
                         blockers: [.memory(needed: shortfall.peak, available: available, size: size, maxLongEdge: nil)])
    }

    /// Search only memory admission, freezing the measured budget. Frame canvas is
    /// kept as an upper bound: hosts must regenerate the actual smaller frame.
    private static func maximumLongEdge(_ request: ExportPlanRequest, budget: Int, upper: Int) -> Int? {
        guard upper > 1 else { return nil }
        func fits(_ edge: Int) -> Bool {
            var candidate = request
            var format = request.choice.customFormat ?? CustomExportFormat(
                encoding: request.choice.destination!.profile.encoding,
                gamut: request.choice.destination!.profile.gamut,
                quality: request.choice.destination!.profile.quality)
            format.longEdge = edge
            candidate.choice = .custom(format)
            return makePlan(candidate, budget: FixedExportMemoryBudget(bytes: budget),
                            preferences: nil, suggestSize: false).memory.fits
        }
        // ROI cost can increase when heavily downsampling. Search from the
        // requested edge down so a narrow admitted interval is never skipped.
        // These are scalar estimates; no image or encoder work is performed.
        for edge in stride(from: upper - 1, through: 1, by: -1) {
            if fits(edge) { return edge }
        }
        return nil
    }

}
