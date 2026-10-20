import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 写回时用的输出变体。每一种都要在图库里试一次，看哪种被接受、哪种保住增益图。
enum OutputVariant: String, CaseIterable, Identifiable, Codable {
    case heicISOGainmap
    case jpegISOGainmap
    case heicISOHDR10
    case heicCoreImage10PQ
    /// 备用路径：自己渲染 SDR 底图，把原图里的增益图原样搬过去（模拟器和部分设备上 ImageIO 不会自动生成增益图时用）。
    case heicCarriedGainMap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heicISOGainmap: "HEIC + ISO 增益图（ImageIO）"
        case .jpegISOGainmap: "JPEG + ISO 增益图（ImageIO）"
        case .heicISOHDR10: "HEIC 10 位 PQ，无增益图（ImageIO ISO HDR）"
        case .heicCoreImage10PQ: "HEIC 10 位 PQ，无增益图（Core Image）"
        case .heicCarriedGainMap: "HEIC 8 位底图 + 搬运原图增益图（ImageIO 辅助数据）"
        }
    }

    var contentType: UTType {
        switch self {
        case .jpegISOGainmap: .jpeg
        default: .heic
        }
    }

    var fileExtension: String { contentType == .jpeg ? "jpg" : "heic" }

    /// 搬运增益图时，底图保持原始像素排列（不转正），方向用标记表示，这样增益图的朝向才对得上。
    var keepsStoredOrientation: Bool { self == .heicCarriedGainMap }

    /// 这个变体预期写出的文件里应该有 ISO 增益图（搬运 Apple 增益图时不一定）。
    var expectsISOGainMap: Bool { self == .heicISOGainmap || self == .jpegISOGainmap }
}

struct WriteReport: Codable {
    var variant: OutputVariant
    var seconds: Double
    var pixelSize: String
}

enum HDRError: LocalizedError {
    case cannotLoad(String)
    case cannotRender
    case cannotCreateDestination
    case finalizeFailed(String)
    case noGainMapToCarry

    var errorDescription: String? {
        switch self {
        case .cannotLoad(let s): "读不出图像：\(s)"
        case .cannotRender: "Core Image 渲染失败"
        case .cannotCreateDestination: "ImageIO 无法创建写出目标"
        case .finalizeFailed(let s): "ImageIO 写出失败：\(s)（模拟器上的 ImageIO 不能从 HDR 像素生成增益图，真机才行）"
        case .noGainMapToCarry: "输入文件里没有增益图可搬运"
        }
    }
}

/// 一个看得出来的小改动（默认 +0.3 EV），以及把结果写成各种变体。
enum HDREditor {
    static let formatIdentifier = "com.hyperdr.photoslab"
    static let formatVersion = "1"

    private static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])

    /// 读入（展开成 HDR，按方向旋正）并提亮。
    static func edited(from url: URL, exposure ev: Double, applyOrientation: Bool = true) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: applyOrientation]) else {
            throw HDRError.cannotLoad(url.lastPathComponent)
        }
        return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
    }

    /// 把 Core Image 图像写成指定变体。
    @discardableResult
    static func write(_ image: CIImage, variant: OutputVariant, to url: URL, gainMapSource: URL? = nil) throws -> WriteReport {
        let start = Date()
        let extent = image.extent.integral
        try? FileManager.default.removeItem(at: url)

        switch variant {
        case .heicCoreImage10PQ:
            guard let pq = CGColorSpace(name: CGColorSpace.displayP3_PQ) else { throw HDRError.cannotRender }
            try context.writeHEIF10Representation(of: image, to: url, colorSpace: pq, options: [:])
        case .heicCarriedGainMap:
            try writeCarried(image, extent: extent, to: url, gainMapSource: gainMapSource)
        case .heicISOGainmap, .jpegISOGainmap, .heicISOHDR10:
            guard let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
                  let cg = context.createCGImage(image, from: extent, format: .RGBAh, colorSpace: linearP3) else {
                throw HDRError.cannotRender
            }
            let request = variant == .heicISOHDR10 ? kCGImageDestinationEncodeToISOHDR : kCGImageDestinationEncodeToISOGainmap
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, variant.contentType.identifier as CFString, 1, nil) else {
                throw HDRError.cannotCreateDestination
            }
            CGImageDestinationAddImage(destination, cg, [kCGImageDestinationEncodeRequest: request] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw HDRError.finalizeFailed(variant.rawValue)
            }
        }
        return WriteReport(variant: variant, seconds: Date().timeIntervalSince(start),
                           pixelSize: "\(Int(extent.width))×\(Int(extent.height))")
    }

    private static func writeCarried(_ image: CIImage, extent: CGRect, to url: URL, gainMapSource: URL?) throws {
        guard let gainMapSource,
              let source = CGImageSourceCreateWithURL(gainMapSource as CFURL, nil) else { throw HDRError.noGainMapToCarry }
        var carried: (CFString, [CFString: Any])?
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [CFString: Any] {
                carried = (type, info)
                break
            }
        }
        guard let (type, info) = carried else { throw HDRError.noGainMapToCarry }
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let cg = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: p3) else {
            throw HDRError.cannotRender
        }
        let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let orientation = sourceProps?[kCGImagePropertyOrientation] { options[kCGImagePropertyOrientation] = orientation }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw HDRError.cannotCreateDestination
        }
        CGImageDestinationAddImage(destination, cg, options as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, type, info as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HDRError.finalizeFailed("heicCarriedGainMap") }
    }

    /// 写进 adjustmentData 的配方。`padding` 用来测大小上限。
    static func recipeData(exposure: Double, variant: OutputVariant, paddingBytes: Int) -> Data {
        var object: [String: Any] = [
            "app": "HyperDR Photos Lab",
            "exposureEV": exposure,
            "variant": variant.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if paddingBytes > 0 { object["padding"] = String(repeating: "x", count: paddingBytes) }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
