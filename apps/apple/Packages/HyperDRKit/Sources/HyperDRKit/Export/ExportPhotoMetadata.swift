import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Portable capture information only. Maker notes, thumbnails and source pixel
/// geometry cannot be carried unchanged onto a rendered, possibly framed photo.
struct ExportPhotoMetadata {
    let properties: [CFString: Any]

    init(source: URL, keepLocation: Bool, size: ExportPixelSize) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let original = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else {
            throw RecipeExportError.verificationFailed("source_metadata_read")
        }
        func subset(_ group: CFString, _ keys: [CFString]) -> [CFString: Any] {
            let values = original[group] as? [CFString: Any] ?? [:]
            return Dictionary(uniqueKeysWithValues: keys.compactMap { key in values[key].map { (key, $0) } })
        }
        var tiff = subset(kCGImagePropertyTIFFDictionary, [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
            kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright])
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "HyperDR"
        var exif = subset(kCGImagePropertyExifDictionary, [kCGImagePropertyExifDateTimeOriginal,
            kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber,
            kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifExposureBiasValue,
            kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm,
            kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel])
        exif[kCGImagePropertyExifPixelXDimension] = size.width
        exif[kCGImagePropertyExifPixelYDimension] = size.height
        var output: [CFString: Any] = [kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: tiff, kCGImagePropertyExifDictionary: exif]
        if keepLocation {
            let gps = subset(kCGImagePropertyGPSDictionary, [kCGImagePropertyGPSVersion,
                kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
                kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef,
                kCGImagePropertyGPSAltitude, kCGImagePropertyGPSAltitudeRef])
            if !gps.isEmpty { output[kCGImagePropertyGPSDictionary] = gps }
        }
        properties = output
    }

    func imageProperties(quality: Int) -> CFDictionary {
        var result = properties
        result[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100
        return result as CFDictionary
    }

    /// ImageIO serializes a bounded TIFF carrier so native packaging can read
    /// the same fields with its existing Exif parser. The carrier's one pixel
    /// is never exported; package reconstructs its safe metadata subset.
    func nativeExif() throws -> Data {
        let data = NSMutableData()
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixel = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else {
            throw RecipeExportError.verificationFailed("export_metadata_write")
        }
        CGImageDestinationAddImage(destination, pixel, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 4 * 1024 * 1024 else {
            throw RecipeExportError.verificationFailed("export_metadata_write")
        }
        return data as Data
    }
}
