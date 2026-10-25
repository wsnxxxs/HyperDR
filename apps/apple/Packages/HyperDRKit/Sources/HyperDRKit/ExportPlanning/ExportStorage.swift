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
        let output = encodedDiskBytes(plan: plan, gainChannels: gainChannels)
        return baseline + replay + staging + output + reserve
    }

    private static func encodedDiskBytes(plan: ExportPlan, gainChannels: Int) -> Int64 {
        let pixels = Int64(plan.size.pixels)
        let metadata: Int64 = 1 << 20
        // libjpeg-turbo's worst-case baseline buffer formula: MCU padding,
        // 2+chroma factor, and 2048 bytes. Base JPEG is 4:2:0; gain is full
        // chroma or grayscale. Keep ICC/Exif/container allowance separately.
        func jpeg(mcu: Int, bytesPerPixel: Int64) -> Int64 {
            let width = Int64((plan.size.width + mcu - 1) / mcu * mcu)
            let height = Int64((plan.size.height + mcu - 1) / mcu * mcu)
            return width * height * bytesPerPixel + 2048
        }
        switch plan.encoding {
        case .sdrTIFF:
            // One RGB16/Deflate staged file, no component or sample spool.
            // Allow 0.1% for Deflate/strip overhead, plus tags and metadata.
            let raw = pixels * 6
            return raw + (raw + 999) / 1000 + metadata
        case .sdrJPEG:
            // One streamed 4:2:0 JPEG, no second disk copy.
            return jpeg(mcu: 16, bytesPerPixel: 3) + metadata
        case .isoGainMapJPEG:
            let components = jpeg(mcu: 16, bytesPerPixel: 3)
                + jpeg(mcu: 8, bytesPerPixel: gainChannels == 1 ? 2 : 6) + metadata
            // Row writing keeps base + auxiliary files beside the assembled
            // result. Whole-plane components live in RAM; framed whole output
            // can retain a verification staging copy beside the result.
            let copies: Int64 = plan.memory.usesRowInput || plan.size != plan.photoSize ? 2 : 1
            return components * copies
        case .adaptive:
            // The native adaptive writer requires a single-channel gain map.
            let auxiliary: Int64 = plan.writer == .inHouse || gainChannels == 1 ? 2 : 6
            let pair = pixels * (8 + auxiliary) + metadata
            // Native HEIC retains both compressed pictures during assembly;
            // ImageIO receives in-memory pictures and writes one destination.
            return pair * (plan.writer == .imageIO ? 1 : 2)
        case .pq, .hlg:
            return (pixels * 8 + metadata) * 2 // Sample spool + final HEIC.
        case .avifPq, .avifHlg:
            // The whole-plane route assembles in RAM; row input retains its
            // compressed sample spool beside the finished file.
            return pixels * 8 * (plan.memory.usesRowInput ? 2 : 1)
        }
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
