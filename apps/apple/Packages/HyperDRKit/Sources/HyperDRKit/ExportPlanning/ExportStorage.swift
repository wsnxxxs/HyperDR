import Darwin
import Foundation
import HyperDREngine

/// Disk owners that can coexist during export. This is an admission estimate;
/// native preallocation and typed write failures remain the final defence.
struct ExportStorage {
    static let reserve: Int64 = 256 << 20

    static func requiredBytes(plan: ExportPlan, source: ExportSource,
                              needsLookBaseline: Bool, baselineAllocated: Bool = false,
                              gainChannels: Int = 3) -> Int64 {
        let pixels = Int64(plan.size.pixels)
        let baseline = needsLookBaseline && !baselineAllocated && source.domain == .rawEDR
            ? Int64(max(source.pixelSize.pixels, source.sensorSize?.pixels ?? 0)) * 16 : 0
        let gain = plan.gainMap.writesGainMap || plan.encoding.isBT2100
        let replay = plan.memory.usesRowInput && gain ? pixels * 4 * Int64(3 + gainChannels) : 0
        let staging = plan.memory.usesRowInput && plan.encoding.isAVIF ? pixels * 6 : 0
        // Allow two encoded copies: the compressed samples and assembled result.
        // Eight bytes/pixel per copy exceeds raw 10-bit 4:4:4 storage plus modest
        // codec overhead; it is an estimate, not a promised compression ratio.
        let output = pixels * 8 * 2
        return baseline + replay + staging + output + reserve
    }

    static func availableBytes(at directory: URL) throws -> Int64 {
        var info = statfs()
        guard directory.withUnsafeFileSystemRepresentation({ statfs($0, &info) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int64(clamping: UInt64(info.f_bavail) * UInt64(info.f_bsize))
    }

    static func check(required: Int64, available: Int64) throws {
        guard required <= available else {
            throw RecipeExportError.insufficientStorage(requiredBytes: required, availableBytes: available)
        }
    }

    static func isStorageFailure(_ error: any Error) -> Bool {
        if let native = error as? HyperDRError { return native.code == "insufficient_storage" }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT) }
        return ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError
    }
}
