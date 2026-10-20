import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import HyperDRRecipe

struct OpenedSource {
    let domain: InputDomain
    let image: CIImage
    let hdr: CIImage
    let baseSpace: CGColorSpace
    let gain: AuthoredGainMap?
    let raw: RAWDevelopment?
    var nativeSize: PixelSize? = nil
}

extension RenderEngine {
    static func open(_ url: URL, options: SourceOptions) throws -> OpenedSource {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw RenderError.cannotOpenSource }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        if options.kind == .raw || (options.kind == .automatic && type?.conforms(to: .rawImage) == true) {
            return try openRAW(url, options: options)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        let auxiliary = [(kCGImageAuxiliaryDataTypeISOGainMap, AuthoredGainMap.Standard.iso),
                         (kCGImageAuxiliaryDataTypeHDRGainMap, .apple)].map { key, standard in
            (standard, CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,key))
        }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let nativeSize = PixelSize(width: orientation >= 5 ? height : width, height: orientation >= 5 ? width : height)
        let baseCG: CGImage
        switch options.resolution {
        case .full:
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RenderError.cannotDecodeSource }
            baseCG = decoded
        case .preview(let maximumSize):
            guard maximumSize.width > 0, maximumSize.height > 0, width > 0, height > 0 else { throw RenderError.invalidSize }
            let scale = min(1,Double(maximumSize.width)/Double(nativeSize.width),Double(maximumSize.height)/Double(nativeSize.height))
            let decodeOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceDecodeRequest: auxiliary.contains { $0.1 != nil } ? kCGImageSourceDecodeToSDR : kCGImageSourceDecodeToHDR,
                kCGImageSourceThumbnailMaxPixelSize: max(1,Int((Double(max(width,height))*scale).rounded(.down)))]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
                throw RenderError.cannotDecodeSource
            }
            baseCG = decoded
        }
        let baseSpace = baseCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let nativeLinear = CGColorSpaceCreateExtendedLinearized(baseSpace)
        let base = CIImage(cgImage: baseCG, options: [.toneMapHDRtoSDR: false])
            .oriented(forExifOrientation: orientation)
        var gain: AuthoredGainMap?
        for (standard, info) in auxiliary {
            guard let info else { continue }
            guard let gainImage = CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true,
                                                                     .applyOrientationProperty: false,
                                                                     .colorSpace: NSNull()]) else {
                throw RenderError.missingGainMap
            }
            let dictionary = info as NSDictionary
            let description = dictionary[kCGImageAuxiliaryDataInfoDataDescription] as? NSDictionary
            let format = (description?["PixelFormat"] as? NSNumber)?.uint32Value ?? 0
            // L008 / L00h / L00f are one channel; RGB auxiliary formats have three.
            let monoFormats: Set<UInt32> = [0x4c303038, 0x4c303068, 0x4c303066]
            let channels = monoFormats.contains(format) ? 1 : 3
            var tags: [String: String] = [:]
            if let metadata = dictionary[kCGImageAuxiliaryDataInfoMetadata] {
                CGImageMetadataEnumerateTagsUsingBlock(metadata as! CGImageMetadata, nil,
                    [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                    if let value = CGImageMetadataTagCopyValue(tag) {
                        tags[path as String] = String(describing: value)
                    }
                    return true
                }
            }
            let gainSpace = dictionary[kCGImageAuxiliaryDataInfoColorSpace].map { $0 as! CGColorSpace }
            gain = AuthoredGainMap(standard: standard, auxiliaryInfo: dictionary,
                image: gainImage.oriented(forExifOrientation: orientation), channelCount: channels,
                baseColorSpace: baseSpace, alternateColorSpace: nil, auxiliaryColorSpace: gainSpace, tags: tags)
            break
        }
        try Task.checkCancellation()
        // Do not classify solely by contentHeadroom: some system ISO decoders report 1
        // for PQ data. PQ/HLG color spaces are HDR even if headroom is unknown.
        let name = baseSpace.name.map { $0 as String } ?? ""
        let isHDR = baseCG.contentHeadroom > 1 || name.contains("PQ") || name.contains("HLG")
        if let gain {
            guard let nativeLinear else { throw RenderError.unsupportedGainColorSpace }
            // The source's unmodified pair is kept in the native base gamut. Use the
            // system's full-headroom reconstruction only after an edit or for display.
            guard let hdr = CIImage(contentsOf: url, options: [.expandToHDR: true,
                                                               .applyOrientationProperty: true]) else {
                throw RenderError.cannotDecodeSource
            }
            let scaleX = base.extent.width/hdr.extent.width, scaleY = base.extent.height/hdr.extent.height
            let previewHDR = hdr.transformed(by:CGAffineTransform(scaleX:scaleX,y:scaleY))
            return OpenedSource(domain: .dual, image: base, hdr: previewHDR,
                                baseSpace: nativeLinear, gain: gain, raw: nil, nativeSize:nativeSize)
        }
        return OpenedSource(domain: isHDR ? .hdr : .sdr, image: base, hdr: base,
                            baseSpace: workingColorSpace, gain: nil, raw: nil, nativeSize:nativeSize)
    }

    static func openRAW(_ url: URL, options: SourceOptions) throws -> OpenedSource {
        guard let filter = CIRAWFilter(imageURL: url) else { throw RenderError.cannotDecodeSource }
        // AE-2 G2: leave file baselineExposure and boostShadowAmount untouched.
        filter.boostAmount = 1
        filter.exposure = 0
        filter.extendedDynamicRangeAmount = 1
        filter.isGamutMappingEnabled = true
        filter.isDraftModeEnabled = false
        let rotated = filter.orientation.rawValue >= 5
        let native = filter.nativeSize
        let nativeSize = PixelSize(width:Int(rotated ? native.height : native.width),
                                   height:Int(rotated ? native.width : native.height))
        switch options.resolution {
        case .full: filter.scaleFactor = 1
        case .preview(let maximumSize):
            guard maximumSize.width > 0, maximumSize.height > 0 else { throw RenderError.invalidSize }
            filter.scaleFactor = Float(min(1,Double(maximumSize.width)/Double(nativeSize.width),
                                          Double(maximumSize.height)/Double(nativeSize.height)))
        }
        if filter.isContrastSupported { filter.contrastAmount = 0 }
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        let raw = options.raw
        if let value = raw.temperature {
            try RenderParameter.check(value,id:"develop.temperature")
            filter.neutralTemperature = value
        }
        if let value = raw.tint {
            try RenderParameter.check(value,id:"develop.tint")
            filter.neutralTint = value
        }
        for (id,value) in [("develop.luminanceNR",raw.luminanceNR),("develop.colorNR",raw.colorNR),("develop.sharpness",raw.sharpness)] {
            if let value { try RenderParameter.check(value,id:id) }
        }
        if filter.isLuminanceNoiseReductionSupported, let value = raw.luminanceNR { filter.luminanceNoiseReductionAmount = value }
        if filter.isColorNoiseReductionSupported, let value = raw.colorNR { filter.colorNoiseReductionAmount = value }
        if filter.isSharpnessSupported, let value = raw.sharpness { filter.sharpnessAmount = value }
        if filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = options.lensCorrection }
        try Task.checkCancellation()
        guard let image = filter.outputImage else { throw RenderError.cannotDecodeSource }
        let development = RAWDevelopment(boost: filter.boostAmount, boostShadow: filter.boostShadowAmount,
            baselineExposure: filter.baselineExposure, localToneMap: filter.localToneMapAmount,
            extendedDynamicRange: filter.extendedDynamicRangeAmount,
            lensCorrectionSupported: filter.isLensCorrectionSupported,
            lensCorrectionApplied: filter.isLensCorrectionSupported && filter.isLensCorrectionEnabled,
            decoderVersion: filter.decoderVersion.rawValue,
            temperature: filter.neutralTemperature, tint: filter.neutralTint,
            luminanceNR: filter.luminanceNoiseReductionAmount, colorNR: filter.colorNoiseReductionAmount,
            sharpness: filter.sharpnessAmount, supportsLuminanceNR: filter.isLuminanceNoiseReductionSupported,
            supportsColorNR: filter.isColorNoiseReductionSupported, supportsSharpness: filter.isSharpnessSupported,
            nativeSize: nativeSize, scaleFactor: filter.scaleFactor, isDraft: filter.isDraftModeEnabled)
        // CIRAWFilter already applies the file's orientation.
        return OpenedSource(domain: .rawEDR, image: image, hdr: image,
                            baseSpace: workingColorSpace, gain: nil, raw: development)
    }
}
