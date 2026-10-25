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
}
