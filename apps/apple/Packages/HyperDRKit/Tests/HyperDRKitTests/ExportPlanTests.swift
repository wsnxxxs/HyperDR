import Foundation
import Testing
@testable import HyperDRKit

private let photo = ExportPixelSize(width: 6000, height: 4000)

private func source(_ kind: ExportSource.Kind = .raster,
                    size: ExportPixelSize = photo,
                    authoredGainChannels: Int = 1) -> ExportSource {
    ExportSource(kind: kind, pixelSize: size, authoredGainChannels: authoredGainChannels)
}

private func request(_ choice: ExportChoice,
                     source: ExportSource = source(),
                     frame: ExportFrameFacts = ExportFrameFacts(),
                     hdrEnabled: Bool = true,
                     peakStops: Double = 2.4,
                     keepsAuthoredGain: Bool = false,
                     library: ExportLibraryFacts = ExportLibraryFacts(origin: .photoLibrary),
                     resources: ExportRetainedResources = ExportRetainedResources()) -> ExportPlanRequest {
    ExportPlanRequest(choice: choice, source: source, frame: frame,
        edit: ExportEditFacts(hdrEnabled: hdrEnabled, peakStops: peakStops,
                              keepsAuthoredGain: keepsAuthoredGain),
        library: library, resources: resources)
}

private func plan(_ request: ExportPlanRequest, available: Int? = nil) -> ExportPlan {
    ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: available))
}

@Suite("Export planning: destinations")
struct ExportDestinationPlanTests {
    @Test func photosWritesAnAdaptivePairAtTheOriginalSize() {
        let plan = plan(request(.destination(.photos)))
        #expect(plan.encoding == .adaptive)
        #expect(plan.baseBitDepth == 8) // an SDR source keeps Main 8
        #expect(plan.writer == .imageIO) // 8-bit base: writer-lab prefers ImageIO
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
        let plan = plan(request(.destination(.photos), source: source(.raw, authoredGainChannels: 1)))
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
        let plan = plan(request(.destination(.web), source: source(.raster, size: small)))
        #expect(plan.size == small)
    }

    @Test func socialWarnsAboutACropOnlyOutsideThePostRange() {
        // 3:2 is inside 4:5 … 1.91:1.
        #expect(plan(request(.destination(.social), peakStops: 1)).notices.isEmpty)
        let tall = ExportPixelSize(width: 3000, height: 6000)
        let plan = plan(request(.destination(.social), source: source(.raster, size: tall), peakStops: 1))
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
        #expect(plan.baseBitDepth == (encoding.isBT2100 ? 10 : 8))
    }

    @Test(arguments: ExportEncoding.allCases)
    func theCeilingIsTheSameOneTheEngineIsTold(_ encoding: ExportEncoding) {
        #expect(encoding.ceilingStops == EditDefaults.maxRange(for: encoding.rawValue))
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
                                source: source(.raw)))
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
        #expect(custom.size == photo) // the long edge is not carried
        #expect(custom.peakStops == destination.peakStops)
    }

    @Test func qualityIsClampedToTheSlider() {
        let plan = plan(request(.custom(CustomExportFormat(encoding: .sdrJPEG, gamut: .srgb, quality: 400))))
        #expect(plan.quality == 100)
    }
}

@Suite("Export planning: the gain map pair")
struct ExportGainMapPlanTests {
    @Test func ourOwnSeparationIsOneChannelWithZeroOffsets() {
        let plan = plan(request(.destination(.web), source: source(.raw)))
        #expect(plan.gainMap.origin == .separated)
        #expect(plan.gainMap.channels == 1)
        #expect(plan.gainMap.usesZeroOffsets)
        #expect(plan.gainMap.resplitReason == nil)
    }

    @Test func anAuthoredPairIsKeptWhenOurWriterCarriesThreeChannels() {
        let plan = plan(request(.destination(.photos),
                                source: source(.dual, authoredGainChannels: 3),
                                hdrEnabled: true, keepsAuthoredGain: true))
        // A dual source is an HDR rendition, so the pair goes to our own writer.
        #expect(plan.writer == .inHouse)
        #expect(plan.gainMap.origin == .authored)
        #expect(plan.gainMap.channels == 3)
        #expect(!plan.gainMap.usesZeroOffsets) // the file's own offsets
    }

    @Test func anAuthoredPairFallsBackToResplitWhenTheWriterCarriesOneChannel() {
        // A dual source never reaches the ImageIO path today (its pair takes a
        // 10-bit base, which our writer owns), so this is the writer capability
        // rule itself: a writer that carries one channel cannot take three.
        let three = ExportPlanner.gainMapPlan(
            request: request(.destination(.photos), source: source(.dual, authoredGainChannels: 3),
                             keepsAuthoredGain: true),
            writer: .imageIO, writesGainMap: true)
        #expect(three.origin == .resplit)
        #expect(three.channels == 1)
        #expect(three.resplitReason == .writerCarriesOneChannel)
    }

    @Test func anEditOutsideTheHDRGroupAlwaysResplits() {
        let plan = plan(request(.destination(.photos), source: source(.dual, authoredGainChannels: 3),
                                keepsAuthoredGain: false))
        #expect(plan.gainMap.origin == .resplit)
        #expect(plan.gainMap.channels == 1)
        #expect(plan.gainMap.resplitReason == .editedBeyondGain)
    }

    @Test func aFramedAuthoredPairKeepsItsMapAndZeroesTheFrame() {
        let plan = plan(request(.destination(.photos), source: source(.dual, authoredGainChannels: 3),
                                frame: ExportFrameFacts(canvas: ExportPixelSize(width: 6200, height: 4200)),
                                keepsAuthoredGain: true))
        #expect(plan.gainMap.origin == .authored)
        #expect(plan.gainMap.channels == 3)
        #expect(plan.gainMap.zeroGainInFrame)
    }

    @Test func aDualSourceWithHDROffWritesNoPair() {
        let plan = plan(request(.destination(.photos), source: source(.dual, authoredGainChannels: 3),
                                hdrEnabled: false, keepsAuthoredGain: true))
        #expect(plan.gainMap == .sdr)
        #expect(plan.peakStops == nil)
    }

    @Test func aframedPairKeepsTheFrameSDR() {
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

    @Test func anUnknownBudgetSkipsAdmission() {
        let plan = plan(request(.destination(.photos)), available: nil)
        #expect(plan.memory.availableBytes == nil)
        #expect(plan.memory.degradation == nil)
        #expect(plan.writer == .imageIO)
        #expect(plan.blockers.isEmpty)
    }

    @Test func theEightBitPairFallsBackToOurWriterWhenImageIODoesNotFit() {
        let preferred = plan(request(.destination(.photos)), available: nil).memory.estimate.peak
        let plan = plan(request(.destination(.photos)), available: preferred - 1)
        #expect(plan.writer == .inHouse)
        #expect(plan.writerReason == .memoryFallback)
        #expect(plan.memory.degradation == .switchedWriter(.inHouse))
        #expect(plan.memory.fits)
        #expect(plan.blockers.isEmpty)
    }

    @Test func aCanvasThatDoesNotFitIsWrittenInStrips() {
        // The composite of a large frame and the pair packaging, not the photo,
        // are what a strip bounds here.
        let canvas = ExportPixelSize(width: 12000, height: 8000)
        let framed = request(.custom(CustomExportFormat(encoding: .isoGainMapJPEG, gamut: .p3, quality: 90)),
                             frame: ExportFrameFacts(canvas: canvas))
        let whole = plan(framed, available: nil).memory.estimate.peak
        let plan = plan(framed, available: whole - 1)
        #expect(plan.memory.degradation == .strips(rowHeight: ExportMemoryEstimate.stripHeight))
        #expect(plan.memory.fits)
        #expect(plan.writer == .inHouse)
        #expect(plan.blockers.isEmpty)
        #expect(plan.memory.estimate.composite == plan.memory.estimate.peak)
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
            isFramed: false, baseBitDepth: 8, writeRows: 1707, retainedBytes: 0))
        #expect(web.encode == sameShape.encode)
        #expect(web.packaging == sameShape.packaging)
        #expect(web.render == sameShape.render)
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

    @Test func aStripCostsLessThanTheWholeCanvas() {
        let whole = plan(request(.destination(.web))).memory.estimate
        let strips = ExportMemoryEstimate.estimate(ExportMemoryEstimate.Input(
            source: source(), photoSize: photo, canvas: photo, encoding: .isoGainMapJPEG,
            writer: .inHouse, writesGainMap: true, isFramed: false, baseBitDepth: 8,
            writeRows: ExportMemoryEstimate.stripHeight, retainedBytes: 0))
        #expect(strips.encode < whole.encode)
        #expect(strips.decode == whole.decode) // decoding is per photo either way
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
                                source: source(.raster, size: photo),
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
