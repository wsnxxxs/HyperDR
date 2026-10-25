import Darwin
import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

struct ExportStorageTests {
    @Test func jointAVIFDemandIncludesFrameBaselineAndBothEncodedCopies() throws {
        let source = ExportSource(domain: .rawEDR, pixelSize: .init(width: 9504, height: 6336))
        let request = ExportPlanRequest(choice: .custom(.init(encoding: .avifPq, quality: 100)),
            source: source, frame: .init(canvas: .init(width: 12800, height: 8600)),
            edit: .init(peakStops: 2))
        let plan = ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: 16 << 30))
        let remaining = ExportStorage.requiredBytes(plan: plan, source: source,
            needsLookBaseline: true, baselineAllocated: true)
        #expect(remaining == Int64(plan.size.pixels) * (24 + 6 + 16) + ExportStorage.reserve)
        let initial = ExportStorage.requiredBytes(plan: plan, source: source, needsLookBaseline: true)
        #expect(initial - remaining == Int64(source.pixelSize.pixels) * 16)
        // The replay alone fits, but the RGB16 staging and two encoded copies
        // do not: reject before rendering rather than after the first scan.
        #expect(throws: RecipeExportError.self) {
            try ExportStorage.check(required: remaining, available: 3_000_000_000)
        }
        try ExportStorage.check(required: remaining, available: remaining)
        #expect(ExportStorage.isStorageFailure(HyperDRError(code: "insufficient_storage", message: "disk full")))
        #expect(ExportStorage.isStorageFailure(POSIXError(.EDQUOT)))
        #expect(!ExportStorage.isStorageFailure(HyperDRError(code: "internal_error", message: "other")))
    }

    @Test func streamedSDROnlyReservesOneOutputFile() throws {
        let source = ExportSource(domain: .sdr, pixelSize: .init(width: 10000, height: 6000))
        for encoding in [ExportEncoding.sdrTIFF, .sdrJPEG] {
            let request = ExportPlanRequest(choice: .custom(.init(encoding: encoding, quality: 100)),
                source: source, edit: .init(hdrEnabled: false, peakStops: 0))
            let plan = ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: 8 << 30))
            #expect(plan.memory.usesRowInput)
            let required = ExportStorage.requiredBytes(plan: plan, source: source, needsLookBaseline: false)
            // 60MP TIFF is about 630 MB including the 256 MiB reserve; a
            // 700 MB volume must admit both SDR formats without a phantom copy.
            try ExportStorage.check(required: required, available: 700_000_000)
            if encoding == .sdrTIFF {
                #expect(required == 360_000_000 + 360_000 + (1 << 20) + ExportStorage.reserve)
            } else {
                #expect(required < 450_000_000)
            }
        }
    }

}
