import Foundation
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 一个辅助数据（增益图、深度图、抠图……）的摘要。
struct AuxiliaryReport: Codable, Equatable {
    var name: String
    var dataBytes: Int
    var description: JSONValue
    /// 元数据标签，例如 Apple 增益图的 hdrgm:* 参数。
    var metadataTags: [String: String]
}

/// 对一个图像文件的检查结果。所有判断都来自 ImageIO / Core Image，不看扩展名。
struct ImageReport: Codable, Equatable {
    var path: String
    var fileName: String
    var fileSize: Int64
    var sha256: String?
    /// ImageIO 认出的类型。
    var imageSourceType: String?
    /// 是否属于 RAW（conforms to public.camera-raw-image）。
    var isRAW: Bool
    var imageCount: Int
    var pixelWidth: Int?
    var pixelHeight: Int?
    var bitDepth: Int?
    var colorProfile: String?
    var orientation: Int?
    var hasAppleHDRGainMap: Bool
    var hasISOGainMap: Bool
    var auxiliary: [AuxiliaryReport]
    /// Core Image 用 expandToHDR 读出来的 headroom（1 表示没有增益图）。
    var headroom: Double?
    /// 展开到 HDR 后的平均线性亮度，用来看编辑前后亮了多少。
    var meanLuminance: Double?
    var error: String?

    var hasAnyGainMap: Bool { hasAppleHDRGainMap || hasISOGainMap }

    /// 日志里的一行摘要。
    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        var parts = [fileName, size]
        if let t = imageSourceType { parts.append(t) }
        if let w = pixelWidth, let h = pixelHeight { parts.append("\(w)×\(h)") }
        if let d = bitDepth { parts.append("\(d) 位") }
        if isRAW { parts.append("RAW") }
        parts.append(hasISOGainMap ? "ISO增益图:有" : "ISO增益图:无")
        parts.append(hasAppleHDRGainMap ? "Apple增益图:有" : "Apple增益图:无")
        if let h = headroom { parts.append(String(format: "headroom %.2f", h)) }
        if let e = error { parts.append("错误:\(e)") }
        return parts.joined(separator: " · ")
    }
}

enum ImageInspector {
    static let auxiliaryTypes: [(String, CFString)] = [
        ("HDRGainMap", kCGImageAuxiliaryDataTypeHDRGainMap),
        ("ISOGainMap", kCGImageAuxiliaryDataTypeISOGainMap),
        ("Depth", kCGImageAuxiliaryDataTypeDepth),
        ("Disparity", kCGImageAuxiliaryDataTypeDisparity),
        ("PortraitEffectsMatte", kCGImageAuxiliaryDataTypePortraitEffectsMatte),
        ("SemanticSegmentationSkinMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte),
        ("SemanticSegmentationHairMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte),
        ("SemanticSegmentationTeethMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte),
        ("SemanticSegmentationGlassesMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte),
        ("SemanticSegmentationSkyMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte),
    ]

    private static let ciContext = CIContext(options: [.workingFormat: CIFormat.RGBAh])

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// - Parameter measureLuminance: 是否解码整幅图算平均亮度（RAW 会自动跳过）。
    static func inspect(_ url: URL, measureLuminance: Bool = true) -> ImageReport {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        var report = ImageReport(
            path: url.path, fileName: url.lastPathComponent, fileSize: size, sha256: sha256(of: url),
            imageSourceType: nil, isRAW: false, imageCount: 0, pixelWidth: nil, pixelHeight: nil,
            bitDepth: nil, colorProfile: nil, orientation: nil,
            hasAppleHDRGainMap: false, hasISOGainMap: false, auxiliary: [],
            headroom: nil, meanLuminance: nil, error: nil)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            report.error = "ImageIO 打不开这个文件"
            return report
        }
        report.imageCount = CGImageSourceGetCount(source)
        if let typeID = CGImageSourceGetType(source) as String? {
            report.imageSourceType = typeID
            if let t = UTType(typeID) { report.isRAW = t.conforms(to: .rawImage) }
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            report.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
            report.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
            report.bitDepth = props[kCGImagePropertyDepth] as? Int
            report.colorProfile = props[kCGImagePropertyProfileName] as? String
            report.orientation = props[kCGImagePropertyOrientation] as? Int
        }
        for (name, type) in auxiliaryTypes {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [CFString: Any] else { continue }
            let bytes = (info[kCGImageAuxiliaryDataInfoData] as? Data)?.count ?? 0
            var tags: [String: String] = [:]
            if let meta = info[kCGImageAuxiliaryDataInfoMetadata], CFGetTypeID(meta as CFTypeRef) == CGImageMetadataGetTypeID() {
                let metadata = meta as! CGImageMetadata
                for tag in (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]) ?? [] {
                    let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
                    let tagName = CGImageMetadataTagCopyName(tag) as String? ?? "?"
                    let value = CGImageMetadataTagCopyValue(tag)
                    tags["\(prefix):\(tagName)"] = String(describing: value ?? "nil" as CFTypeRef)
                }
            }
            let desc = JSONValue.from(any: info[kCGImageAuxiliaryDataInfoDataDescription])
            report.auxiliary.append(AuxiliaryReport(name: name, dataBytes: bytes, description: desc, metadataTags: tags))
            if name == "HDRGainMap" { report.hasAppleHDRGainMap = true }
            if name == "ISOGainMap" { report.hasISOGainMap = true }
        }

        if measureLuminance && !report.isRAW,
           let image = CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: true]) {
            report.headroom = Double(image.contentHeadroom)
            report.meanLuminance = meanLuminance(of: image)
        }
        return report
    }

    static func meanLuminance(of image: CIImage) -> Double? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return nil }
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixel = [Float](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        ciContext.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBAf, colorSpace: space)
        return Double(0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2])
    }
}
