import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRKit

private let photo = ExportPixelSize(width: 6000, height: 4000)

private func source(_ domain: InputDomain = .sdr,
                    size: ExportPixelSize = photo) -> ExportSource {
    ExportSource(domain: domain, pixelSize: size)
}

private func request(_ choice: ExportChoice,
                     source: ExportSource = source(),
                     pair: ExportGainPair? = nil,
                     frame: ExportFrameFacts = ExportFrameFacts(),
                     hdrEnabled: Bool = true,
                     peakStops: Double = 2.4,
                     library: ExportLibraryFacts = ExportLibraryFacts(origin: .photoLibrary),
                     resources: ExportRetainedResources = ExportRetainedResources()) -> ExportPlanRequest {
    ExportPlanRequest(choice: choice, source: source, pair: pair, frame: frame,
        edit: ExportEditFacts(hdrEnabled: hdrEnabled, peakStops: peakStops),
        library: library, resources: resources)
}

private func plan(_ request: ExportPlanRequest, available: Int? = 8_000_000_000) -> ExportPlan {
    ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: available))
}

@Suite("Export planning: destinations")
struct ExportDestinationPlanTests {
    @Test func photosWritesAnAdaptivePairAtTheOriginalSize() {
        let plan = plan(request(.destination(.photos)))
        #expect(plan.encoding == .adaptive)
        #expect(plan.baseBitDepth == 8) // an SDR source keeps Main 8
        #expect(plan.writer == .imageIO)
        #expect(plan.writerReason == .qualityAtEqualSize)
        #expect(plan.gamut == .p3)
        #expect(plan.size == photo)
        #expect(plan.longEdgeLimit == nil)
        #expect(plan.keepLocation)
        #expect(plan.peakStops == 2.4)
        #expect(plan.gainMap.origin == .separated)
        #expect(plan.handling == .photoLibrary)
        #expect(plan.library?.selected == .replace)
        #expect(plan.blockers.isEmpty)
    }

    @Test func photosTakesATenBitBaseForAnHDRRendition() {
        let plan = plan(request(.destination(.photos), source: source(.rawEDR)))
        #expect(plan.encoding == .adaptive)
        #expect(plan.baseBitDepth == 10)
        #expect(plan.writer == .inHouse)
        #expect(plan.writerReason == .peakMemory)
    }

    @Test func photosWithHDRSwitchedOffWritesAnEightBitSDRHEIC() {
        let plan = plan(request(.destination(.photos), hdrEnabled: false))
        #expect(plan.encoding == .adaptive)
        #expect(plan.baseBitDepth == 8)
        #expect(plan.writer == .imageIO)
        #expect(plan.writerReason == .noComparison) // no pair to package
        #expect(plan.peakStops == nil)
        #expect(plan.gainMap == .sdr)
        #expect(plan.summary.parts.count == 3) // no peak
    }

    @Test func webWritesAGainMapJPEGAt2560AndDropsTheLocation() {
        let plan = plan(request(.destination(.web), peakStops: 4))
        #expect(plan.encoding == .isoGainMapJPEG)
        #expect(plan.writer == .inHouse)
        #expect(plan.writerReason == .qualityAtEqualSize)
        #expect(plan.quality == 90)
        #expect(!plan.keepLocation)
        #expect(plan.size == ExportPixelSize(width: 2560, height: 1707))
        #expect(plan.longEdgeLimit == 2560)
        #expect(plan.peakStops == 3) // the destination narrows the edit's 4
        #expect(plan.handling == .file)
        #expect(plan.library == nil)
        #expect(plan.notices.map(\.key) == ["dest.ceiling %@"])
    }

    @Test func webWithHDRSwitchedOffWritesAP3JPEG() {
        let plan = plan(request(.destination(.web), hdrEnabled: false))
        #expect(plan.encoding == .sdrJPEG)
        #expect(plan.gamut == .p3)
        #expect(plan.quality == 90)
        #expect(plan.size.longEdge == 2560)
        #expect(plan.gainMap == .sdr)
        #expect(plan.peakStops == nil)
    }

    @Test func socialWritesAGainMapJPEGAt2160WithTwoStops() {
        let plan = plan(request(.destination(.social), peakStops: 3))
        #expect(plan.encoding == .isoGainMapJPEG)
        #expect(plan.quality == 92)
        #expect(plan.size == ExportPixelSize(width: 2160, height: 1440))
        #expect(plan.peakStops == 2)
        #expect(plan.handling == .share)
        #expect(!plan.keepLocation)
        #expect(plan.notices.map(\.key) == ["dest.ceiling %@"])
    }

    @Test func socialWithHDRSwitchedOffWritesSRGB() {
        let plan = plan(request(.destination(.social), hdrEnabled: false))
        #expect(plan.encoding == .sdrJPEG)
        #expect(plan.gamut == .srgb)
    }

    @Test func aLongEdgeLimitNeverUpscales() {
        let small = ExportPixelSize(width: 1200, height: 900)
        let plan = plan(request(.destination(.web), source: source(.sdr, size: small)))
        #expect(plan.size == small)
    }

    @Test func socialWarnsAboutACropOnlyOutsideThePostRange() {
        // 3:2 is inside 4:5 … 1.91:1.
        #expect(plan(request(.destination(.social), peakStops: 1)).notices.isEmpty)
        let tall = ExportPixelSize(width: 3000, height: 6000)
        let plan = plan(request(.destination(.social), source: source(.sdr, size: tall), peakStops: 1))
        #expect(plan.notices.map(\.key) == ["dest.social.aspect"])
    }

    @Test func theDestinationTableMatchesTheDesign() {
        let photos = DestinationProfile.photos
        #expect(photos.encoding == .adaptive && photos.sdrEncoding == .adaptive)
        #expect(photos.ceilingStops == 3 && photos.gamut == .p3 && photos.longEdge == nil)
        #expect(photos.keepLocation && photos.handling == .photoLibrary)

        let web = DestinationProfile.web
        #expect(web.encoding == .isoGainMapJPEG && web.sdrEncoding == .sdrJPEG)
        #expect(web.ceilingStops == 3 && web.longEdge == 2560 && web.quality == 90)
        #expect(!web.keepLocation)

        let social = DestinationProfile.social
        #expect(social.ceilingStops == 2 && social.longEdge == 2160 && social.quality == 92)
        #expect(social.sdrGamut == .srgb)
    }
}

@Suite("Export planning: custom formats")
struct ExportCustomPlanTests {
    @Test(arguments: ExportEncoding.allCases)
    func everyEncodingKeepsItsCeiling(_ encoding: ExportEncoding) {
        let plan = plan(request(.custom(CustomExportFormat(encoding: encoding, gamut: .p3, quality: 88)),
                                peakStops: 9))
        #expect(plan.encoding == encoding)
        #expect(plan.quality == 88)
        #expect(plan.longEdgeLimit == nil)
        #expect(plan.size == photo)
        #expect(plan.keepLocation)
        #expect(plan.handling == .file)
        #expect(plan.library == nil)
        let ceiling = min(9, encoding.ceilingStops)
        #expect(plan.peakStops == (encoding.isSDR ? nil : ceiling))
        // A single-rendition source keeps Main 8; BT.2100 formats are 10-bit.
        #expect(plan.baseBitDepth == (encoding.isBT2100 ? 10 : encoding == .sdrTIFF ? 16 : 8))
    }

    @Test func everyEncodingPicksTheWriterOfThePipelineTable() {
        let expected: [ExportEncoding: (ExportWriter, ExportWriterReason)] = [
            .adaptive: (.imageIO, .qualityAtEqualSize),
            .isoGainMapJPEG: (.inHouse, .qualityAtEqualSize),
            .pq: (.inHouse, .peakMemory),
            .hlg: (.inHouse, .peakMemory),
            .avifPq: (.libavif, .onlyEncoder),
            .avifHlg: (.libavif, .onlyEncoder),
            .sdrJPEG: (.inHouse, .noComparison),
            .sdrTIFF: (.inHouse, .noComparison),
        ]
        for (encoding, writer) in expected {
            let plan = plan(request(.custom(CustomExportFormat(encoding: encoding, gamut: .srgb, quality: 90))))
            #expect(plan.writer == writer.0, "\(encoding)")
            #expect(plan.writerReason == writer.1, "\(encoding)")
        }
    }

    @Test func anHDRRenditionMovesTheAdaptivePairToOurWriter() {
        let plan = plan(request(.custom(CustomExportFormat(encoding: .adaptive, gamut: .p3, quality: 90)),
                                source: source(.rawEDR)))
        #expect(plan.baseBitDepth == 10)
        #expect(plan.writer == .inHouse)
    }

    @Test func bt2100FormatsDefineTheirOwnPrimaries() {
        let pq = plan(request(.custom(CustomExportFormat(encoding: .pq, gamut: .srgb, quality: 90))))
        #expect(pq.gamut == .rec2020)
        // The page's gamut control does not apply to these four encodings.
        #expect(pq.gamutIsFixedByFormat)
        #expect(!plan(request(.custom(CustomExportFormat(encoding: .sdrJPEG, gamut: .srgb, quality: 90))))
            .gamutIsFixedByFormat)
    }

    @Test func aDestinationCarriesItsSettingsIntoCustom() {
        let destination = plan(request(.destination(.web)))
        let custom = plan(request(.custom(destination.customCarryingSettings)))
        #expect(custom.encoding == destination.encoding)
        #expect(custom.gamut == destination.gamut)
        #expect(custom.quality == destination.quality)
        #expect(custom.size == destination.size) // the destination limit is carried
        #expect(custom.peakStops == destination.peakStops)
    }

    @Test func qualityIsClampedToTheSlider() {
        let plan = plan(request(.custom(CustomExportFormat(encoding: .sdrJPEG, gamut: .srgb, quality: 400))))
        #expect(plan.quality == 100)
    }
}

@Suite("Export planning: the gain map pair")
struct ExportGainMapPlanTests {
    /// As the render describes its output: ours, or the photo's own pair.
    private func pair(_ provenance: ExportGainPair.Provenance, channels: Int = 1,
                      offsetsAreZero: Bool = true) -> ExportGainPair {
        ExportGainPair(provenance: provenance, channels: channels, offsetsAreZero: offsetsAreZero)
    }

    @Test func ourOwnSeparationIsOneChannelWithZeroOffsets() {
        let plan = plan(request(.destination(.web), source: source(.rawEDR)))
        #expect(plan.gainMap.origin == .separated)
        #expect(plan.gainMap.channels == 1)
        #expect(plan.gainMap.offsetsAreZero)
        #expect(plan.gainMap.resplitReason == nil)
    }

    @Test func aSingleHDRSourceIsAnHDRRendition() {
        // R14-001: an HDR HEIC or AVIF carries real values above SDR white, so the
        // adaptive pair takes a 10-bit base and our writer — not an 8-bit SDR base
        // written by ImageIO.
        let plan = plan(request(.destination(.photos), source: source(.hdr)))
        #expect(plan.baseBitDepth == 10)
        #expect(plan.writer == .inHouse)
        #expect(plan.writerReason == .peakMemory)
    }

    @Test func anEditedAuthoredPairKeepsTheChannelsTheRenderReported() {
        // R14-002: an HDR-only edit on a one-channel authored map can come back as
        // three channels; the plan reads what the render produced, not the file.
        let plan = plan(request(.destination(.photos), source: source(.dual),
                                pair: pair(.editedAuthored, channels: 3, offsetsAreZero: false)))
        #expect(plan.writer == .inHouse)
        #expect(plan.gainMap.origin == .resplit)
        #expect(plan.gainMap.channels == 1)
        #expect(plan.gainMap.offsetsAreZero) // the file's own offsets
    }

    @Test func anAuthoredPairFallsBackToResplitWhenTheWriterCarriesOneChannel() {
        // A dual source takes a 10-bit base, which our writer owns. Its
        // single-channel contract still requires a three-channel pair to split.
        let three = ExportPlanner.gainMapPlan(
            request: request(.destination(.photos), source: source(.dual),
                             pair: pair(.editedAuthored, channels: 3)),
            writer: .inHouse, writesGainMap: true)
        #expect(three.origin == .resplit)
        #expect(three.channels == 1)
        #expect(three.offsetsAreZero)
        #expect(three.resplitReason == .writerCarriesOneChannel)
    }

    @Test func aResplitFromTheRenderIsTakenAsItIs() {
        let plan = plan(request(.destination(.photos), source: source(.dual),
                                pair: pair(.resplit)))
        #expect(plan.gainMap.origin == .resplit)
        #expect(plan.gainMap.channels == 1)
        #expect(plan.gainMap.offsetsAreZero)
        #expect(plan.gainMap.resplitReason == nil) // the render re-separated, not us
    }

    @Test func aDualSourceWithoutAPairDescriptionIsPlannedAsAResplit() {
        let plan = plan(request(.destination(.photos), source: source(.dual)))
        #expect(plan.gainMap.origin == .resplit)
        #expect(plan.gainMap.channels == 1)
        #expect(plan.gainMap.resplitReason == nil)
    }

    @Test func aFramedAuthoredPairKeepsItsMapAndZeroesTheFrame() {
        let plan = plan(request(.destination(.photos), source: source(.dual),
                                pair: pair(.authored, channels: 3, offsetsAreZero: false),
                                frame: ExportFrameFacts(canvas: ExportPixelSize(width: 6200, height: 4200))))
        #expect(plan.gainMap.origin == .resplit)
        #expect(plan.gainMap.resplitReason == .frameRequiresNeutralPair)
        #expect(plan.gainMap.channels == 1)
        #expect(plan.gainMap.zeroGainInFrame)
    }

    @Test func aDualSourceWithHDROffWritesNoPair() {
        let plan = plan(request(.destination(.photos), source: source(.dual),
                                pair: pair(.authored, channels: 3), hdrEnabled: false))
        #expect(plan.gainMap == .sdr)
        #expect(plan.peakStops == nil)
    }

    @Test func aFramedPairKeepsTheFrameSDR() {
        let framed = plan(request(.destination(.web),
                                  frame: ExportFrameFacts(canvas: ExportPixelSize(width: 6200, height: 4200))))
        #expect(framed.gainMap.zeroGainInFrame)
        let unframed = plan(request(.destination(.web)))
        #expect(!unframed.gainMap.zeroGainInFrame)
    }

    @Test func anSDRFormatWritesNoGainMap() {
        let plan = plan(request(.custom(CustomExportFormat(encoding: .sdrTIFF, gamut: .p3, quality: 90))))
        #expect(plan.gainMap == .sdr)
        #expect(!plan.gainMap.writesGainMap)
        #expect(plan.gainMap.zeroGainInFrame == false)
    }

    @Test func theHDRSwitchRemovesThePairFromEveryFormat() {
        for encoding in [ExportEncoding.adaptive, .isoGainMapJPEG] {
            let plan = plan(request(.custom(CustomExportFormat(encoding: encoding, gamut: .p3, quality: 90)),
                                    hdrEnabled: false))
            #expect(plan.gainMap == .sdr, "\(encoding)")
            #expect(plan.peakStops == nil)
        }
    }
}

@Suite("Export planning: memory admission")
struct ExportMemoryPlanTests {
    @Test func aLargeBudgetTakesThePreferredWriter() {
        let plan = plan(request(.destination(.photos)), available: 8_000_000_000)
        #expect(plan.memory.degradation == nil)
        #expect(plan.memory.availableBytes == 8_000_000_000)
        #expect(plan.memory.fits)
        #expect(plan.writer == .imageIO)
    }

    @Test func nonSDRBaseHeadroomSelectsNativeWriter() {
        let result = plan(request(.destination(.photos),
            pair: ExportGainPair(provenance: .authored, baseHeadroom: 0.5)))
        #expect(result.isExecutable)
        #expect(result.writer == .inHouse)
        #expect(result.writerReason == .unsupportedCapability)
        #expect(result.gainMap.resplitReason == .writerHeadroomContract)
        #expect(!ExportWriter.imageIO.capabilities(encoding: .adaptive, bitDepth: 8,
            gainChannels: 1, baseHeadroom: 0.5).supported)
    }

    @Test func framedHEICUsesTheWriterWithCompressionProtection() {
        let result = plan(request(.destination(.photos), frame: ExportFrameFacts(canvas: photo)))
        #expect(result.writer == .inHouse)
        #expect(result.writerReason == .frameGainProtection)
        #expect(result.gainMap.zeroGainInFrame)
    }

    @Test func anUnknownBudgetUsesAConservativeLimit() {
        let plan = plan(request(.destination(.photos)), available: nil)
        #expect(plan.memory.availableBytes == 256 * 1024 * 1024)
        #expect(plan.memory.degradation == .refused)
        #expect(!plan.isExecutable)
    }

    @Test func anAVIFCanvasThatDoesNotFitIsRefused() {
        let canvas = ExportPixelSize(width: 12000, height: 8000)
        let framed = request(.custom(CustomExportFormat(encoding: .avifPq, gamut: .p3, quality: 90)),
                             frame: ExportFrameFacts(canvas: canvas))
        let whole = plan(framed).memory.estimate.peak
        let result = plan(framed, available: whole - 1)
        #expect(result.memory.degradation == .refused)
        #expect(!result.memory.fits)
        #expect(!result.isExecutable)
    }

    @Test func incrementalRowsCanShrinkCPUBuffers() {
        let framed = request(.custom(.init(encoding: .isoGainMapJPEG, gamut: .p3, quality: 90)),
            frame: ExportFrameFacts(canvas: .init(width: 12000, height: 8000)))
        let preferred = plan(framed)
        let reduced = plan(framed, available: preferred.memory.estimate.peak - 1)
        #expect(reduced.memory.usesRowInput && reduced.isExecutable)
        #expect(reduced.memory.renderRows < preferred.memory.renderRows)
        #expect(reduced.memory.estimate.peak < preferred.memory.estimate.peak)
    }

    @Test func whatNoWriterFitsIsRefusedWithAReason() {
        let plan = plan(request(.destination(.photos)), available: 64 << 20)
        #expect(plan.memory.degradation == .refused)
        #expect(!plan.isExecutable)
        #expect(plan.blockers.map(\.code) == ["export_memory_exceeded"])
        #expect(plan.blockers[0].message.key == "dest.memoryExceeded %@ %@")
    }

    @Test func aFramedCanvasCostsMoreThanTheBarePhoto() {
        let custom = ExportChoice.custom(CustomExportFormat(encoding: .isoGainMapJPEG, gamut: .p3, quality: 90))
        let bare = plan(request(custom)).memory.estimate.peak
        let canvas = ExportPixelSize(width: 12000, height: 8000)
        let framed = plan(request(custom, frame: ExportFrameFacts(canvas: canvas))).memory.estimate.peak
        #expect(framed > bare)
    }

    @Test func admissionPricesTheSizeThatIsWritten() {
        // The web export writes 2560 × 1707, so its estimate must not be charged
        // for the photo's 6000 × 4000 canvas.
        let web = plan(request(.destination(.web))).memory.estimate
        let written = ExportPixelSize(width: 2560, height: 1707)
        let sameShape = ExportMemoryEstimate.estimate(ExportMemoryEstimate.Input(
            source: source(), photoSize: written, canvas: written,
            encoding: .isoGainMapJPEG, writer: .inHouse, writesGainMap: true,
            isFramed: false, baseBitDepth: 8, writeRows: 256, retainedBytes: 0))
        #expect(web.encode == sameShape.encode)
        #expect(web.packaging == sameShape.packaging)
        #expect(web.render == sameShape.render)
    }

    @Test func aLUTCostsThreeSixteenByteCopiesPerValue() {
        // R14-003: the CPU table ([SIMD3<Float>], 16-byte stride), the rgba32Float
        // 3D texture and the SIMD4 upload staging array.
        #expect(ExportRetainedResources(lutValueCount: 129 * 129 * 129).bytes
                == 129 * 129 * 129 * 48)
        #expect(ExportRetainedResources(lutAssetBytes: 1024, lutValueCount: 10,
                                        frameOverlayPixels: 100).bytes
                == 1024 + 10 * 48 + 100 * 16)
    }

    @Test func retainedResourcesAreCountedInEveryStage() {
        let resources = ExportRetainedResources(lutAssetBytes: 1 << 20, lutValueCount: 1024,
                                                frameSpecificationBytes: 2048,
                                                frameOverlayBytes: 1 << 16,
                                                frameOverlayPixels: 2048)
        let bare = plan(request(.destination(.web))).memory.estimate
        let loaded = plan(request(.destination(.web), resources: resources)).memory.estimate
        #expect(loaded.peak == bare.peak + resources.bytes)
        #expect(loaded.decode == bare.decode + resources.bytes)
    }

    @Test func smallerRenderStripesDoNotEliminateThePlaneOwners() {
        let whole = ExportMemoryEstimate.estimate(ExportMemoryEstimate.Input(
            source: source(), photoSize: photo, canvas: photo, encoding: .isoGainMapJPEG,
            writer: .inHouse, writesGainMap: true, isFramed: false, baseBitDepth: 8,
            writeRows: photo.height, retainedBytes: 0, allowsRowInput: false))
        let strips = ExportMemoryEstimate.estimate(ExportMemoryEstimate.Input(
            source: source(), photoSize: photo, canvas: photo, encoding: .isoGainMapJPEG,
            writer: .inHouse, writesGainMap: true, isFramed: false, baseBitDepth: 8,
            writeRows: 64, retainedBytes: 0, allowsRowInput: false))
        // Readback has both RGBA and packed RGB for base and gain (56 B/px),
        // beside GPU RGBA outputs (32 B/px). Shrinking stripes only frees those.
        let freedStripePixels = photo.width * (photo.height - 64)
        #expect(whole.render - strips.render >= freedStripePixels * (56 + 32))
        #expect(strips.encode == whole.encode)
        #expect(strips.packaging == whole.packaging)
    }

    @Test func rowsBoundNativeAndSubsampleSystemVerification() {
        let req = request(.custom(.init(encoding: .sdrTIFF, gamut: .p3, quality: 90)))
        let streamed = plan(req)
        var old = req; old.allowsRowInput = false
        let whole = plan(old)
        #expect(streamed.memory.usesRowInput && !whole.memory.usesRowInput)
        #expect(streamed.memory.estimate.encode < whole.memory.estimate.encode)
        #expect(streamed.memory.estimate.systemVerify - streamed.memory.estimate.decode < 32 << 20)
        #expect(streamed.memory.estimate.nativeVerify < streamed.memory.estimate.systemVerify)
        #expect(streamed.memory.estimate.verify == streamed.memory.estimate.systemVerify)
        #expect(whole.memory.estimate.nativeVerify == whole.memory.estimate.systemVerify)
        #expect(!ExportWriter.imageIO.supportsRowInput(encoding: .adaptive))
        #expect(!ExportWriter.libavif.supportsRowInput(encoding: .avifPq))
    }

    @Test func nativeRowVerificationWorkspaceDoesNotGrowWithHeight() {
        for encoding in [ExportEncoding.sdrJPEG, .sdrTIFF, .isoGainMapJPEG, .adaptive, .pq, .hlg] {
            func estimate(_ height: Int) -> ExportMemoryEstimate {
                let size = ExportPixelSize(width: 2048, height: height)
                return ExportMemoryEstimate.estimate(.init(source: source(size: size), photoSize: size,
                    canvas: size, encoding: encoding, writer: .inHouse, writesGainMap: encoding.writesGainMap,
                    isFramed: false, baseBitDepth: encoding.isBT2100 ? 10 : 8, writeRows: 64, retainedBytes: 0))
            }
            let short = estimate(1024), tall = estimate(4096)
            // Source/analysis cache belongs to decode; the verification workspace
            // remains one row set or tile pair at the same width.
            #expect(tall.nativeVerify - tall.decode == short.nativeVerify - short.decode)
            #expect(tall.systemVerify - tall.decode == short.systemVerify - short.decode)
            #expect(tall.verify == max(tall.nativeVerify, tall.systemVerify))
        }
        for encoding in [ExportEncoding.avifPq, .adaptive] {
            let writer: ExportWriter = encoding.isAVIF ? .libavif : .imageIO
            let result = ExportMemoryEstimate.estimate(.init(source: source(), photoSize: photo, canvas: photo,
                encoding: encoding, writer: writer, writesGainMap: encoding.writesGainMap,
                isFramed: false, baseBitDepth: encoding.isAVIF ? 10 : 8, writeRows: 64, retainedBytes: 0))
            #expect(result.nativeVerify == result.systemVerify)
            #expect(result.verify > photo.pixels * 16)
        }
    }

    @Test func unknownMetalLimitIsNotAZeroByteBudget() {
        #expect(ExportMemoryDiagnostic.gpuFailure(required: 256 << 20, recommended: 0) == nil)
        #expect(ExportMemoryDiagnostic.gpuFailure(required: 256 << 20, recommended: 512 << 20) == nil)
        let failure = ExportMemoryDiagnostic.gpuFailure(required: 512 << 20, recommended: 256 << 20)
        #expect(failure?.check == .gpu && failure?.requiredMiB == 512 && failure?.availableMiB == 256)
        #expect(failure?.summary.contains("shortfall=256.0 MiB") == true)
    }

    @Test func heifAssemblyPricesBorrowedSamplesAndOutputSeparatelyFromEncoding() {
        let size = ExportPixelSize(width: 12800, height: 8600)
        let memory = ExportMemoryEstimate.estimate(.init(source: source(.rawEDR, size: size),
            photoSize: size, canvas: size, encoding: .adaptive, writer: .inHouse,
            writesGainMap: true, isFramed: false, baseBitDepth: 10, writeRows: 256,
            retainedBytes: 0, quality: 95))
        let oneCopy = ExportMemoryEstimate.compressedHEICCache(pixels: size.pixels, bitDepth: 10, quality: 95) / 2
        let slab = size.width * 512 * 12
        #expect(memory.packaging - memory.encode == oneCopy - slab)
        #expect(memory.packaging > memory.encode)
        #expect(memory.peak == memory.packaging)
    }

    @Test func fullSizeRAWMemoryEstimates() {
        for size in [ExportPixelSize(width: 9504, height: 6336), ExportPixelSize(width: 12800, height: 8600)] {
            for encoding in [ExportEncoding.adaptive, .isoGainMapJPEG] {
                let planned = plan(request(.custom(.init(encoding: encoding, gamut: .p3, quality: 95)),
                    source: source(.rawEDR, size: size)))
                #expect(planned.memory.usesRowInput && planned.writer == .inHouse)
                for rows in [256, 128, 64] {
                    let estimate = ExportMemoryEstimate.estimate(.init(source: source(.rawEDR, size: size),
                        photoSize: size, canvas: size, encoding: encoding, writer: .inHouse, writesGainMap: true,
                        isFramed: false, baseBitDepth: encoding == .adaptive ? 10 : 8, writeRows: rows, retainedBytes: 0, quality: 95))
                    let workspace = (encoding == .adaptive ? 512*512*40 : size.width*128) + 8*1024*1024
                    let before = estimate.nativeVerify - workspace + size.pixels*40
                    #expect(estimate.systemVerify < before)
                    if rows == 256 { #expect(estimate == planned.memory.estimate) }
                    #expect(estimate.decode == size.pixels * 24 + (512 << 20))
                    #expect(estimate.fits(in: 4 << 30))
                    if ProcessInfo.processInfo.environment["HYPERDR_MEMORY_ESTIMATES"] == "1" {
                        print("RAW_MEMORY", encoding.rawValue, "width", size.width, "height", size.height, "rows", rows,
                            "decode", estimate.decode, "render", estimate.render,
                            "packaging", estimate.packaging, "encode", estimate.encode, "peak", estimate.peak)
                    }
                }
            }
        }
    }

    @Test func rowOwnersFollowRenderReadLimitAndGainChannels() {
        let size = ExportPixelSize(width: 20017, height: 8600)
        func estimate(rows: Int, channels: Int) -> ExportMemoryEstimate {
            ExportMemoryEstimate.estimate(.init(source: source(.rawEDR, size: size),
                photoSize: size, canvas: size, encoding: .isoGainMapJPEG, writer: .inHouse,
                writesGainMap: true, isFramed: false, baseBitDepth: 8, writeRows: rows,
                retainedBytes: 0, gainChannels: channels))
        }
        let mono = estimate(rows: 256, channels: 1), rgb = estimate(rows: 256, channels: 3)
        // Two CPU row owners plus the contract's extra RGB tile packing scratch.
        #expect(rgb.encode - mono.encode == 2 * 4 * 2 * size.width * 256 + (24 << 20))
        #expect(estimate(rows: 4096, channels: 3) == estimate(rows: 512, channels: 3))
        #expect(ExportMemoryEstimate.rowGPUBytes(maximumTextureDimension: 8192)
            == ExportMemoryEstimate.rowGPUBytes(maximumTextureDimension: 16384))
        #expect(ExportMemoryEstimate.rowGPUBytes(maximumTextureDimension: 16384) < 512 << 20)
    }

    @Test func fullSizeRAWAdmissionUsesRemainingBudgetAndRefusesDecoderShortfall() {
        let size = ExportPixelSize(width: 12800, height: 8600)
        for encoding in [ExportEncoding.adaptive, .isoGainMapJPEG] {
            let input = request(.custom(.init(encoding: encoding, quality: 95)), source: source(.rawEDR, size: size))
            // Scenario: a 5 GiB usable process ceiling with 1 GiB already held
            // by the editor. Budget is remaining memory, not total device RAM.
            let admitted = plan(input, available: (5 << 30) - (1 << 30))
            #expect(admitted.isExecutable && admitted.photoSize == size)
            #expect(admitted.memory.renderRows == 256)
            let refused = plan(input, available: 2800 << 20)
            #expect(!refused.isExecutable)
            // Downscaling cannot remove native Apple decoder residency.
            #expect(refused.memory.maxAdmissibleLongEdge == nil)
        }
    }

    @Test func macAndSimulatorBudgetUseTheHostPhysicalShare() {
        #if os(macOS) || targetEnvironment(simulator)
        #expect(SystemExportMemoryBudget(physicalShare: 0.25).availableBytes()
            == Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.25))
        #expect(SystemExportMemoryBudget(physicalShare: 0).availableBytes() == nil)
        #endif
    }

    @Test func theSystemBudgetAnswersOrDeclines() {
        // Whatever the host reports, the answer is either a positive budget or
        // an explicit "cannot say" — never a guess of zero.
        if let bytes = SystemExportMemoryBudget().availableBytes() {
            #expect(bytes > 0)
        }
    }
}

@Suite("Export planning: saving to Photos")
struct ExportLibraryPlanTests {
    @Test func aLibraryPhotoReplacesTheOriginalByDefault() {
        let plan = plan(request(.destination(.photos),
                                library: ExportLibraryFacts(origin: .photoLibrary, access: .notDetermined)))
        #expect(plan.library?.selected == .replace)
        #expect(plan.library?.replace?.isAvailable == true)
        #expect(plan.library?.newPhoto?.isAvailable == true)
    }

    @Test func aFileOnlyBecomesANewPhoto() {
        let plan = plan(request(.destination(.photos),
                                library: ExportLibraryFacts(origin: .files, access: .addOnly)))
        #expect(plan.library?.selected == .newPhoto)
        #expect(plan.library?.replace?.unavailableReasonKey == "dest.photos.replace.files")
        #expect(plan.library?.newPhoto?.isAvailable == true)
    }

    @Test func aFrameCannotBePutBackOverTheOriginal() {
        let plan = plan(request(.destination(.photos),
                                frame: ExportFrameFacts(canvas: ExportPixelSize(width: 6200, height: 4200)),
                                library: ExportLibraryFacts(origin: .photoLibrary)))
        #expect(plan.library?.selected == .newPhoto)
        #expect(plan.library?.replace?.unavailableReasonKey == "dest.photos.replace.framed")
    }

    @Test func limitedAccessNeedsTheWholeLibraryToReplace() {
        let limited = plan(request(.destination(.photos),
            library: ExportLibraryFacts(origin: .photoLibrary, access: .readWrite(canReplaceSelected: false))))
        #expect(limited.library?.selected == .newPhoto)
        #expect(limited.library?.replace?.unavailableReasonKey == "dest.photos.replace.libraryAccess")
        let authorized = plan(request(.destination(.photos),
            library: ExportLibraryFacts(origin: .photoLibrary, access: .readWrite(canReplaceSelected: true))))
        #expect(authorized.library?.selected == .replace)
        let addOnly = plan(request(.destination(.photos),
            library: ExportLibraryFacts(origin: .photoLibrary, access: .addOnly)))
        #expect(addOnly.library?.replace?.unavailableReasonKey == "dest.photos.replace.addOnly")
    }

    @Test func refusedAccessBlocksTheExport() {
        let plan = plan(request(.destination(.photos),
                                library: ExportLibraryFacts(origin: .photoLibrary, access: .denied)))
        #expect(plan.library?.selected == nil)
        #expect(plan.blockers.map(\.code) == ["photos_permission_denied"])
        #expect(!plan.isExecutable)
    }

    @Test func theRememberedModeWinsWhenItIsStillAvailable() {
        let preferences = InMemoryExportPreferences(mode: .newPhoto)
        let planned = ExportPlanner.plan(request(.destination(.photos),
            library: ExportLibraryFacts(origin: .photoLibrary, access: .readWrite(canReplaceSelected: true))),
            budget: FixedExportMemoryBudget(bytes: nil), preferences: preferences)
        #expect(planned.library?.selected == .newPhoto)
    }

    @Test func aRememberedModeThatIsNoLongerAvailableFallsBack() {
        // Remembered replacement, but a frame now makes it impossible.
        let preferences = InMemoryExportPreferences(mode: .replace)
        let planned = ExportPlanner.plan(request(.destination(.photos),
            frame: ExportFrameFacts(canvas: ExportPixelSize(width: 6200, height: 4200)),
            library: ExportLibraryFacts(origin: .photoLibrary)),
            budget: FixedExportMemoryBudget(bytes: nil), preferences: preferences)
        #expect(planned.library?.selected == .newPhoto)
    }

    @Test func aPreferenceStoreRemembersWhatItIsGiven() {
        let preferences = InMemoryExportPreferences()
        #expect(preferences.lastLibrarySaveMode() == nil)
        preferences.rememberLibrarySaveMode(.newPhoto)
        #expect(preferences.lastLibrarySaveMode() == .newPhoto)
    }

    @Test func publishingDestinationsHaveNoLibraryChoice() {
        for destination in [ExportDestination.web, .social] {
            let plan = plan(request(.destination(destination)))
            #expect(plan.library == nil, "\(destination)")
        }
    }
}

@Suite("Export planning: the Will write summary")
struct ExportSummaryTests {
    @Test func photosNamesItsEncodingGamutSizeAndPeak() {
        let summary = plan(request(.destination(.photos))).summary
        #expect(summary.labelKey == "dest.willWrite")
        #expect(summary.parts.map(\.key) == ["enc.adaptive.label", "choice.colorGamut.p3",
                                             "plan.size.original", "plan.peak %@"])
        #expect(summary.parts[3].arguments == [.stops(2.4)])
    }

    @Test func aResizedDestinationNamesBothSides() {
        let summary = plan(request(.destination(.web))).summary
        #expect(summary.parts[2].key == "plan.size.pixels")
        #expect(summary.parts[2].arguments == [.pixels(2560), .pixels(1707)])
    }

    @Test func anSDRExportHasNoPeak() {
        let summary = plan(request(.destination(.photos), hdrEnabled: false)).summary
        #expect(summary.parts.map(\.key) == ["enc.adaptive.label", "choice.colorGamut.p3",
                                             "plan.size.original"])
    }

    @Test func stopsAreWrittenWithASignAndAtMostOneDecimal() {
        #expect(ExportPlanText.stops(2.4) == "+2.4")
        #expect(ExportPlanText.stops(3) == "+3")
        #expect(ExportPlanText.stops(2.34) == "+2.3")
        #expect(ExportPlanText.bytes(3_100_000_000) == "3.1 GB")
        #expect(ExportPlanText.bytes(400_000_000) == "400 MB")
    }

    @Test func aClampedPeakSaysWhatTheDestinationAllows() {
        let plan = plan(request(.destination(.social), peakStops: 3))
        #expect(plan.notices.map(\.key) == ["dest.ceiling %@"])
        #expect(plan.notices.first?.arguments == [.stops(2)])
    }

    @Test func aCustomFormatUsesTheFormatsOwnNotice() {
        let plan = plan(request(.custom(CustomExportFormat(encoding: .hlg, gamut: .p3, quality: 90)),
                                peakStops: 4))
        #expect(plan.notices.map(\.key) == ["export.rangeClamped %@ %@"])
        #expect(plan.notices.first?.arguments == [.key("enc.hlg.label"), .stops(2.3)])
    }
}

@Suite("Export planning: geometry")
struct ExportGeometryTests {
    @Test func aLandscapeLongEdgeSetsTheWidth() {
        #expect(photo.fitted(longEdge: 2560) == ExportPixelSize(width: 2560, height: 1707))
    }

    @Test func aPortraitLongEdgeSetsTheHeight() {
        let portrait = ExportPixelSize(width: 4000, height: 6000)
        #expect(portrait.fitted(longEdge: 2160) == ExportPixelSize(width: 1440, height: 2160))
    }

    @Test func noLimitOrASmallerOneKeepsTheSize() {
        #expect(photo.fitted(longEdge: nil) == photo)
        #expect(photo.fitted(longEdge: 6000) == photo)
        #expect(photo.fitted(longEdge: 9000) == photo)
    }

    @Test func theLongEdgeLimitsThePhotoAndAFrameIsLaidOutAroundIt() {
        // The plan states the photo's written size so the caller can lay the
        // frame out; the canvas it hands back is then written as it is.
        #expect(ExportPlanner.photoSize(for: .destination(.web), photo: photo)
                == ExportPixelSize(width: 2560, height: 1707))
        let canvas = ExportPixelSize(width: 2816, height: 1963)
        let plan = plan(request(.destination(.web),
                                source: source(.sdr, size: photo),
                                frame: ExportFrameFacts(canvas: canvas)))
        #expect(plan.photoSize == ExportPixelSize(width: 2560, height: 1707))
        #expect(plan.size == canvas)
        #expect(plan.gainMap.zeroGainInFrame)
    }

    @Test func aFramedExportNamesTheCanvasItWrites() {
        let canvas = ExportPixelSize(width: 6200, height: 4200)
        let plan = plan(request(.destination(.photos),
                                frame: ExportFrameFacts(canvas: canvas)))
        #expect(plan.size == canvas)
        #expect(plan.summary.parts[2].key == "plan.size.pixels")
        #expect(plan.summary.parts[2].arguments == [.pixels(6200), .pixels(4200)])
    }
}

@Suite("Export planning: functional gaps")
struct ExportPlanGapTests {
    @Test func customLongEdgeFlowsIntoSizeSnapshotAndKey() throws {
        let limited = plan(request(.custom(.init(encoding: .sdrJPEG, longEdge: 1800))))
        #expect(limited.photoSize == .init(width: 1800, height: 1200))
        #expect(limited.longEdgeLimit == 1800)
        let layout = try ExportPlanner.frameLayout(frame: ["margins": .number(0.05), "caption": .number(0.1)],
            choice: limited.choice, photo: photo)
        #expect(layout.photo.width == 1800 && layout.photo.height == 1200)
        let framed = plan(request(limited.choice, frame: .init(canvas: .init(width: layout.width, height: layout.height))))
        #expect(framed.photoSize == limited.photoSize)
        #expect(framed.size == .init(width: layout.width, height: layout.height))
        #expect(framed.memory.estimate.peak >= limited.memory.estimate.peak)
        #expect(plan(request(.custom(.init(longEdge: 9000)))).photoSize == photo)
        let recipe = Recipe(inputDomain: .sdr)
        let snapshot = RecipeExportSnapshot(recipe: recipe, source: .init(sha256: "test", byteCount: 1, modificationDate: .distantPast))
        let resolved = ResolvedExportSnapshot(snapshot: snapshot, plan: limited)
        let restored = try JSONDecoder().decode(ResolvedExportSnapshot.self, from: JSONEncoder().encode(resolved))
        #expect(restored.selection.customFormat?.longEdge == 1800)
        #expect(restored.width == 1800 && restored.height == 1200)
        let original = ResolvedExportSnapshot(snapshot: snapshot, plan: plan(request(.custom(.init(encoding: .sdrJPEG)))))
        #expect(try resolved.exportKey() != original.exportKey())
        // Existing serialized choices without longEdge remain readable.
        let format = try JSONDecoder().decode(CustomExportFormat.self, from: Data(#"{"encoding":"adaptive","gamut":"p3","quality":90}"#.utf8))
        #expect(format.longEdge == nil)
    }

    @Test func hdrOffNoticesAndBT2100Blockers() {
        for encoding in ExportEncoding.allCases {
            let value = plan(request(.custom(.init(encoding: encoding)), hdrEnabled: false))
            #expect(value.blockers.contains { $0.code == "hdrOff" } == encoding.isBT2100)
            #expect(value.notices.contains { $0.key == "plan.sdrVersion" } == encoding.writesGainMap)
            if encoding == .isoGainMapJPEG { #expect(value.encoding == .sdrJPEG) }
            if encoding == .adaptive { #expect(value.baseBitDepth == 8 && !value.gainMap.writesGainMap) }
        }
    }

    @Test func memoryFailureSuggestsAnAdmittedBoundary() throws {
        for (encoding, sourceSize, budget) in [
            (ExportEncoding.avifPq, photo, 900_000_000),
            (.isoGainMapJPEG, ExportPixelSize(width: 12800, height: 8600), 3 << 30)
        ] {
            let input = request(.custom(.init(encoding: encoding)), source: source(.rawEDR, size: sourceSize))
            let refused = plan(input, available: budget)
            #expect(!refused.memory.fits)
            #expect(refused.blockers.first { $0.code == "export_memory_exceeded" }?.pixelSize == sourceSize)
            let edge = try #require(refused.memory.maxAdmissibleLongEdge)
            var smaller = input
            smaller.choice = .custom(.init(encoding: encoding, longEdge: edge))
            #expect(plan(smaller, available: budget).memory.fits)
            smaller.choice = .custom(.init(encoding: encoding, longEdge: edge + 1))
            #expect(!plan(smaller, available: budget).memory.fits)
            #expect(plan(input, available: 1).memory.maxAdmissibleLongEdge == nil)
        }
    }

    @Test func planMessagesResolveInBothLanguages() {
        for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans")] {
            for encoding in ExportEncoding.allCases {
                for hdr in [true, false] {
                    let value = plan(request(.custom(.init(encoding: encoding)), hdrEnabled: hdr, peakStops: 8), available: 1)
                    for message in value.notices + value.blockers.map(\.message) + value.summary.parts {
                        #expect(message.localized(locale: locale) != message.key)
                        #expect(!message.localized(locale: locale).contains("%@"))
                    }
                }
            }
        }
    }
}
