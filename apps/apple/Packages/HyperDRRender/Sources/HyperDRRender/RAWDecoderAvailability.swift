import CoreImage
import Foundation

extension RenderEngine {
    /// The RAW decoder generations this system offers at all, independent of
    /// any camera. Probed once on a synthetic DNG: the versions CIRAWFilter
    /// lists for it are the system's own claim (`9.dng` only where RAW 9 exists).
    public nonisolated static let systemRAWDecoderGenerations: Set<Int> = {
        guard let filter = CIRAWFilter(imageData: DecoderProbeDNG.data,
                                       identifierHint: "com.adobe.raw-image") else { return [] }
        return Set(filter.supportedDecoderVersions.compactMap { Int($0.rawValue.split(separator: ".").first ?? "") })
    }()

    public nonisolated static var systemSupportsRAW9: Bool { systemRAWDecoderGenerations.contains(9) }
}

/// A 256 x 256 uncompressed RGGB DNG, built in memory. ImageIO reads smaller
/// CFA images as plain TIFF, so the size is the smallest it accepts as RAW.
private enum DecoderProbeDNG {
    static let data: Data = {
        let side: UInt32 = 256
        var entries: [(tag: UInt16, type: UInt16, count: UInt32, payload: [UInt8])] = []
        func short(_ tag: UInt16, _ values: [UInt16]) { entries.append((tag, 3, UInt32(values.count), values.flatMap(le16))) }
        func long(_ tag: UInt16, _ values: [UInt32]) { entries.append((tag, 4, UInt32(values.count), values.flatMap(le32))) }
        func byte(_ tag: UInt16, _ values: [UInt8]) { entries.append((tag, 1, UInt32(values.count), values)) }
        func ascii(_ tag: UInt16, _ text: String) {
            let bytes = Array(text.utf8) + [0]
            entries.append((tag, 2, UInt32(bytes.count), bytes))
        }
        func rational(_ tag: UInt16, signed: Bool, _ values: [Int32]) {
            entries.append((tag, signed ? 10 : 5, UInt32(values.count),
                            values.flatMap { le32(UInt32(bitPattern: $0)) + le32(10_000) }))
        }
        let pixelBytes = side * side * 2
        long(254, [0])                      // NewSubfileType: main image
        long(256, [side]); long(257, [side])
        short(258, [16]); short(259, [1])   // 16-bit, uncompressed
        short(262, [32803])                 // CFA
        ascii(271, "HyperDR"); ascii(272, "Decoder Probe")
        long(273, [0])                      // StripOffsets, set below
        short(277, [1]); long(278, [side]); long(279, [pixelBytes]); short(284, [1])
        short(33421, [2, 2]); byte(33422, [0, 1, 1, 2])
        byte(50706, [1, 4, 0, 0]); byte(50707, [1, 1, 0, 0])
        ascii(50708, "HyperDR Decoder Probe")
        byte(50710, [0, 1, 2]); short(50711, [1])
        long(50717, [4095])
        // XYZ D65 -> linear sRGB stands in for a camera matrix.
        rational(50721, signed: true, [32404, -15371, -4985, -9692, 18760, 416, 556, -2040, 10572])
        rational(50728, signed: false, [10_000, 10_000, 10_000])
        short(50778, [21])
        entries.sort { $0.tag < $1.tag }

        let directoryOffset = 8
        let extraBase = directoryOffset + 2 + entries.count * 12 + 4
        var directory = le16(UInt16(entries.count))
        var extra: [UInt8] = []
        var stripOffsetAt = 0
        for entry in entries {
            directory += le16(entry.tag) + le16(entry.type) + le32(entry.count)
            if entry.tag == 273 {
                stripOffsetAt = directory.count
                directory += [0, 0, 0, 0]
            } else if entry.payload.count <= 4 {
                directory += entry.payload + Array(repeating: 0, count: 4 - entry.payload.count)
            } else {
                if extra.count % 2 == 1 { extra.append(0) }
                directory += le32(UInt32(extraBase + extra.count))
                extra += entry.payload
            }
        }
        directory += le32(0)
        if extra.count % 2 == 1 { extra.append(0) }
        directory.replaceSubrange(stripOffsetAt..<stripOffsetAt + 4, with: le32(UInt32(extraBase + extra.count)))
        var bytes: [UInt8] = [0x49, 0x49, 42, 0] + le32(UInt32(directoryOffset)) + directory + extra
        bytes += Array(repeating: [0x00, 0x04], count: Int(side * side)).flatMap { $0 }
        return Data(bytes)
    }()

    private static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8)] }
    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xff) } }
}
