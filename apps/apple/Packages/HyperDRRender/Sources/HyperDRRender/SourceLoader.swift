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
    var modelCapture: ModelGainCapture = .empty
    var nativeSize: PixelSize? = nil
    var rawPreviewSize: PixelSize? = nil
    var draftRAWPreview = false
    /// The full size before `applying(_:)`, once a geometry is applied.
    var uncroppedSize: PixelSize? = nil

    /// Resolution never changes the native CIRAWFilter graph. Both ordinary
    /// opening and shared-graph analysis use this exact sizing/metadata policy.
    func rawVariant(resolution: SourceResolution) throws -> Self {
        guard let raw else { throw RenderError.cannotDecodeSource }
        let scale: Double
        switch resolution {
        case .full: scale = 1
        case .preview(let bound):
            guard bound.width > 0, bound.height > 0 else { throw RenderError.invalidSize }
            scale = min(1, Double(bound.width) / Double(raw.nativeSize.width),
                        Double(bound.height) / Double(raw.nativeSize.height))
        }
        return Self(domain: domain, image: image, hdr: hdr, baseSpace: baseSpace,
            gain: gain, raw: raw.atPreviewScale(Float(scale)), modelCapture: modelCapture, nativeSize: nativeSize,
            rawPreviewSize: scale < 1 ? PixelSize(
                width: max(1, Int((image.extent.width * scale).rounded())),
                height: max(1, Int((image.extent.height * scale).rounded()))) : nil,
            draftRAWPreview: draftRAWPreview, uncroppedSize: uncroppedSize)
    }

}

/// ImageIO sizes the untransformed image. A preview bound, however, describes
/// the photo after its crop/turn/perspective, just like a RAW preview's bound.
private struct RasterPreviewPlan {
    let maximumDimension: Int
    let outputSize: PixelSize?

    init(bound: PixelSize, native: PixelSize, geometry: Geometry) throws {
        guard bound.width > 0, bound.height > 0, native.width > 0, native.height > 0 else {
            throw RenderError.invalidSize
        }
        let longSide = max(native.width, native.height)
        guard !geometry.isIdentity else {
            let scale = min(1, Double(bound.width) / Double(native.width), Double(bound.height) / Double(native.height))
            maximumDimension = max(1, Int((Double(longSide) * scale).rounded(.down)))
            outputSize = nil
            return
        }
        let photo = GeometrySize(width: Double(native.width), height: Double(native.height))
        let full = geometry.outputSize(of: photo)
        let scale = min(1, Double(bound.width) / Double(full.width), Double(bound.height) / Double(full.height))
        let target = PixelSize(width: max(1, Int((Double(full.width) * scale).rounded())),
                               height: max(1, Int((Double(full.height) * scale).rounded())))
        // The thumbnail's short edge and geometry's crop round independently.
        // Keep two output pixels of support, then resize the transformed photo
        // to the exact target. This also leaves support for edge interpolation.
        let crop = geometry.cropRect(for: photo)
        let decodeScale = min(1, max(Double(target.width + 2) / crop.width,
                                     Double(target.height + 2) / crop.height))
        maximumDimension = min(longSide, max(1, Int((Double(longSide) * decodeScale).rounded(.up))))
        outputSize = target
    }

    func applying(to opened: OpenedSource) -> OpenedSource {
        guard let outputSize else { return opened }
        let bounds = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        func resize(_ image: CIImage) -> CIImage {
            let extent = image.extent
            guard extent != bounds else { return image }
            return image.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: bounds.width / extent.width,
                                                  y: bounds.height / extent.height)
                    .translatedBy(x: -extent.minX, y: -extent.minY))
                .cropped(to: bounds)
        }
        let image = resize(opened.image)
        return OpenedSource(domain: opened.domain, image: image,
            hdr: opened.hdr === opened.image ? image : resize(opened.hdr),
            baseSpace: opened.baseSpace, gain: opened.gain, raw: opened.raw,
            modelCapture: opened.modelCapture,
            nativeSize: opened.nativeSize, rawPreviewSize: opened.rawPreviewSize,
            uncroppedSize: opened.uncroppedSize)
    }
}

extension RenderEngine {
    static func open(_ url: URL, options: SourceOptions, deferred: Bool = false,
                     progress: (@Sendable (SourceLoadPhase) -> Void)? = nil) throws -> OpenedSource {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw RenderError.cannotOpenSource }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let capture = ModelGainCapture(properties: properties)
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        if options.kind == .raw || (options.kind == .automatic && type?.conforms(to: .rawImage) == true) {
            progress?(.loadingDecoder)
            var opened = try openRAW(url, options: options)
            opened.modelCapture = capture
            return opened
        }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        let auxiliary = [(kCGImageAuxiliaryDataTypeISOGainMap, AuthoredGainMap.Standard.iso),
                         (kCGImageAuxiliaryDataTypeHDRGainMap, .apple)].map { key, standard in
            (standard, CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,key))
        }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        // Missing source dimensions are malformed input, not an invalid
        // preview size supplied by the caller.
        guard width > 0, height > 0 else { throw RenderError.cannotDecodeSource }
        let nativeSize = PixelSize(width: orientation >= 5 ? height : width, height: orientation >= 5 ? width : height)
        let preview: RasterPreviewPlan?
        switch options.resolution {
        case .full: preview = nil
        case .preview(let bound): preview = try RasterPreviewPlan(bound: bound, native: nativeSize, geometry: options.geometry)
        }
        // Core Image can omit a large TIFF provider's final tile under concurrent
        // rendering, even for a full load. Detach its complete native bitmap for
        // both full and lazy sources; this also avoids re-decoding strips per ROI.
        // This is decoder storage, not a full-size float Render texture.
        let cacheTIFF = type == .tiff && max(nativeSize.width,nativeSize.height) > 4096
            && !auxiliary.contains { $0.1 != nil }
        let baseCG: CGImage
        switch options.resolution {
        case .full:
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, deferred ? [kCGImageSourceShouldCache:false] as CFDictionary : nil) else { throw RenderError.cannotDecodeSource }
            if cacheTIFF, let data = decoded.dataProvider?.data,
               let provider = CGDataProvider(data:data),
               let bitmap = CGImage(width:decoded.width,height:decoded.height,
                    bitsPerComponent:decoded.bitsPerComponent,bitsPerPixel:decoded.bitsPerPixel,
                    bytesPerRow:decoded.bytesPerRow,space:decoded.colorSpace ?? CGColorSpace(name:CGColorSpace.sRGB)!,
                    bitmapInfo:decoded.bitmapInfo,provider:provider,decode:decoded.decode,
                    shouldInterpolate:decoded.shouldInterpolate,intent:decoded.renderingIntent) {
                baseCG = CGImageCreateCopyWithContentHeadroom(decoded.contentHeadroom,bitmap) ?? bitmap
            } else { baseCG = decoded }
        case .preview:
            var decodeOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: preview!.maximumDimension]
            // The default decode retains the native base of an authored pair,
            // including a PQ/HLG HDR base. DecodeToSDR would tone-map that base
            // while retaining its original gain metadata; DecodeToHDR would
            // reconstruct the pair and then apply its gain a second time.
            if !auxiliary.contains(where: { $0.1 != nil }) {
                decodeOptions[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
            }
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
                throw RenderError.cannotDecodeSource
            }
            baseCG = decoded
        }
        let baseSpace = baseCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let nativeLinear = CGColorSpaceCreateExtendedLinearized(baseSpace)
        let base: CIImage
        if deferred, !cacheTIFF, max(nativeSize.width,nativeSize.height) > 4096, !auxiliary.contains(where:{ $0.1 != nil }),
           let fileImage = CIImage(contentsOf:url,options:[.toneMapHDRtoSDR:false,.applyOrientationProperty:true]) {
            // Other large rasters keep Core Image's file/region provider.
            // TIFF uses the reusable native bitmap detached above; bounded
            // (<=4096) rasters keep the cheaper ImageIO CGImage provider.
            base = fileImage
        } else {
            base = CIImage(cgImage:baseCG,options:[.toneMapHDRtoSDR:false]).oriented(forExifOrientation:orientation)
        }
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
            let opened = try OpenedSource(domain: .dual, image: base, hdr: previewHDR,
                                baseSpace: nativeLinear, gain: gain, raw: nil, modelCapture: capture, nativeSize:nativeSize)
                .applying(options.geometry)
            return preview?.applying(to: opened) ?? opened
        }
        let opened = try OpenedSource(domain: isHDR ? .hdr : .sdr, image: base, hdr: base,
                            baseSpace: workingColorSpace, gain: nil, raw: nil, modelCapture: capture, nativeSize:nativeSize)
            .applying(options.geometry)
        return preview?.applying(to: opened) ?? opened
    }

    /// Resolve an explicit generation for a newly opened photo. Raster inputs
    /// have no RAW decoder; an unsupported RAW generation must never fall back.
    public func rawDecoder(_ url: URL, generation: Int) throws -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source),
              UTType(identifier as String)?.conforms(to: .rawImage) == true else { return nil }
        guard let filter = CIRAWFilter(imageURL: url) else { throw RenderError.cannotDecodeSource }
        let version = String(generation)
        guard let supported = filter.supportedDecoderVersions.first(where: {
            $0.rawValue == version || $0.rawValue == version + ".dng"
        }) else { throw RenderError.unsupportedRAWDecoder(version) }
        return supported.rawValue
    }

    /// New photos prefer generation 9, then 8 (including their DNG variants).
    /// Older cameras without either retain their supported system default.
    public func preferredRAWDecoder(_ url: URL) -> String? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        return Self.selectRAWDecoder(supported: filter.supportedDecoderVersions.map(\.rawValue),
                                     systemDefault: filter.decoderVersion.rawValue)
    }

    /// Retry generation 8 explicitly: the system default may itself be 9.
    public func fallbackRAWDecoder(_ url: URL) -> String? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        return Self.selectRAWDecoder(supported: filter.supportedDecoderVersions.map(\.rawValue),
                                     systemDefault: filter.decoderVersion.rawValue, allowing9: false)
    }

    nonisolated static func selectRAWDecoder(supported: [String], systemDefault: String,
                                             allowing9: Bool = true) -> String? {
        let versions = supported.filter { !$0.isEmpty && $0 != CIRAWDecoderVersion.none.rawValue }
        for generation in allowing9 ? ["9", "8"] : ["8"] {
            if let version = versions.first(where: { $0.split(separator: ".").first == Substring(generation) }) {
                return version
            }
        }
        // Never retry a known failed generation or silently select a future one.
        guard versions.contains(systemDefault),
              let generation = Int(systemDefault.split(separator: ".").first ?? ""), generation < 9 else { return nil }
        return systemDefault
    }

    /// Used by legacy recipes that deliberately retain the system default.
    public func defaultRAWDecoder(_ url: URL) -> String? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let version = filter.decoderVersion
        guard version != .none, !version.rawValue.isEmpty,
              filter.supportedDecoderVersions.contains(version) else { return nil }
        return version.rawValue
    }

    static func openRAW(_ url: URL, options: SourceOptions) throws -> OpenedSource {
        guard let filter = CIRAWFilter(imageURL: url) else { throw RenderError.cannotDecodeSource }
        // An unavailable recorded decoder must fail rather than silently change a saved edit.
        if let version = options.rawDecoderVersion {
            guard let supported = filter.supportedDecoderVersions.first(where: { $0.rawValue == version }) else {
                throw RenderError.unsupportedRAWDecoder(version)
            }
            filter.decoderVersion = supported
        }
        // AE-2 G2: leave file baselineExposure untouched. Apple's boost is a tone
        // curve (2026-10-22: scene 0.18 lands near 0.385, ratio ~1.29 at 0.90), so a
        // log look develops at boost 0 and keeps that baseline. Measured on Sony,
        // Canon and Leica: boostShadowAmount does not move pixels while boost is 0;
        // it is still cleared so the record matches the scene-linear development.
        filter.boostAmount = options.sceneLinear ? 0 : 1
        if options.sceneLinear { filter.boostShadowAmount = 0 }
        filter.exposure = 0
        filter.extendedDynamicRangeAmount = 1
        // Extended linear P3 can carry colours outside P3 as signed components.
        // Preserve them through the Log/film input transform; fit at the output.
        filter.isGamutMappingEnabled = !options.sceneLinear
        filter.isDraftModeEnabled = false
        let rotated = filter.orientation.rawValue >= 5
        let native = filter.nativeSize
        let nativeSize = PixelSize(width:Int(rotated ? native.height : native.width),
                                   height:Int(rotated ? native.width : native.height))
        // Final previews develop bounded native ROIs. Only the temporary
        // editable preview opts into CIRAWFilter's reduced demosaic.
        filter.scaleFactor = 1
        var draft = false
        if options.draftRAWPreview, case .preview(let bound) = options.resolution {
            guard bound.width > 0, bound.height > 0 else { throw RenderError.invalidSize }
            let cropped = options.geometry.outputSize(of: nativeSize)
            let scale = min(0.5, Double(bound.width) / Double(cropped.width),
                            Double(bound.height) / Double(cropped.height))
            // A reduced demosaic keeps the same decoder, boost and RAW settings.
            filter.scaleFactor = Float(max(0.125, scale))
            draft = true
        }
        if filter.isContrastSupported { filter.contrastAmount = 0 }
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        // Capture camera/Apple defaults before applying recipe overrides. UI values
        // use recipe units; CIRAWFilter's applied scalar fields remain engine units.
        let sourceValues: [String:Double] = [
            "develop.temperature":Double(filter.neutralTemperature), "develop.tint":Double(filter.neutralTint),
            "develop.luminanceNR":Double(filter.luminanceNoiseReductionAmount)*100,
            "develop.colorNR":Double(filter.colorNoiseReductionAmount)*100,
            "develop.sharpness":Double(filter.sharpnessAmount)*100]
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
        guard let decoded = filter.outputImage else { throw RenderError.cannotDecodeSource }
        // Keep geometry and preview sizing in native coordinates. The paired
        // transforms collapse when rasterized; CIRAWFilter still develops reduced pixels.
        let sx = Double(nativeSize.width) / decoded.extent.width
        let sy = Double(nativeSize.height) / decoded.extent.height
        let output = draft ? decoded.clampedToExtent().transformed(by: CGAffineTransform(
            a: sx, b: 0, c: 0, d: sy, tx: -decoded.extent.minX * sx, ty: -decoded.extent.minY * sy))
            .cropped(to: CGRect(x: 0, y: 0, width: nativeSize.width, height: nativeSize.height)) : decoded
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
            nativeSize: nativeSize, developedExtent: output.extent.size,
            scaleFactor: 1, isDraft: filter.isDraftModeEnabled, sourceValues:sourceValues)
        // CIRAWFilter already applies the file's orientation. The geometry goes
        // before the preview scale, which is then measured on the cropped photo.
        return try OpenedSource(domain: .rawEDR, image: output, hdr: output,
                            baseSpace: workingColorSpace, gain: nil, raw: development, draftRAWPreview: draft)
            .applying(options.geometry).rawVariant(resolution: options.resolution)
    }
}
