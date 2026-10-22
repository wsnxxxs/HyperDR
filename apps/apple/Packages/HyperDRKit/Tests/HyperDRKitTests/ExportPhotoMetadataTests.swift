import Foundation
import HyperDRRecipe
import HyperDRRender
import ImageIO
import Testing
@testable import HyperDRKit

private func captureProperties() -> [CFString: Any] {
    [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera maker",
        kCGImagePropertyTIFFModel: "Camera model", kCGImagePropertyTIFFArtist: "Photographer"],
     kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:22 12:34:56",
        kCGImagePropertyExifExposureTime: 1.0 / 125, kCGImagePropertyExifFNumber: 2.8,
        kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifExposureBiasValue: -0.3,
        kCGImagePropertyExifFocalLength: 35, kCGImagePropertyExifFocalLenIn35mmFilm: 50,
        kCGImagePropertyExifLensMake: "Lens maker", kCGImagePropertyExifLensModel: "Lens model",
        kCGImagePropertyExifMakerNote: Data([1, 2, 3, 4])],
     kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 27.5, kCGImagePropertyGPSLatitudeRef: "S",
        kCGImagePropertyGPSLongitude: 153.0, kCGImagePropertyGPSLongitudeRef: "E"]]
}

private func properties(_ url: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

private func expectCapture(_ output: [CFString: Any], location: Bool) throws {
    let tiff = try #require(output[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    let exif = try #require(output[kCGImagePropertyExifDictionary] as? [CFString: Any])
    #expect(tiff[kCGImagePropertyTIFFMake] as? String == "Camera maker")
    #expect(tiff[kCGImagePropertyTIFFModel] as? String == "Camera model")
    #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "Photographer")
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:22 12:34:56")
    #expect(exif[kCGImagePropertyExifLensModel] as? String == "Lens model")
    #expect((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue == 400)
    #expect(abs(((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue ?? 0) - 1.0 / 125) < 0.00001)
    #expect(abs(((exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue ?? 0) + 0.3) < 0.0001)
    #expect(exif[kCGImagePropertyExifMakerNote] == nil)
    #expect(output[kCGImagePropertyOrientation] as? Int == 1)
    let gps = output[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    #expect((gps != nil) == location)
    if location {
        #expect(gps?[kCGImagePropertyGPSLatitudeRef] as? String == "S")
        #expect(gps?[kCGImagePropertyGPSLatitude] as? Double == 27.5)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct ExportPhotoMetadataTests {
    @Test func portableMetadataDiscardsSourceGeometryAndPrivateTags() throws {
        let photo = try TinyPhoto(properties: captureProperties()); defer { photo.remove() }
        for keepLocation in [true, false] {
            let metadata = try ExportPhotoMetadata(source: photo.url, keepLocation: keepLocation,
                size: .init(width: 112, height: 88))
            try expectCapture(metadata.properties, location: keepLocation)
            let exif = try #require(metadata.properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            #expect(exif[kCGImagePropertyExifPixelXDimension] as? Int == 112)
            #expect(exif[kCGImagePropertyExifPixelYDimension] as? Int == 88)
            let bytes = try metadata.nativeExif()
            #expect(bytes.count < 4096)
            let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            try expectCapture(try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]),
                location: keepLocation)
        }
    }

    @Test func captureSurvivesNativeRowsWholeAndImageIOWriters() async throws {
        let photo = try TinyPhoto(properties: captureProperties())
        let env = try await RecipeExportEnvironment(photo: photo); defer { env.remove() }
        let service = env.service()
        for encoding in [ExportEncoding.adaptive, .pq, .hlg, .isoGainMapJPEG, .sdrJPEG, .avifPq, .avifHlg] {
            for rows in [true, false] {
                var request = env.request(encoding)
                request.allowsRowInput = rows
                let result = try await service.export(session: env.session.id, snapshot: env.snapshot(), request: request)
                try expectCapture(properties(result.file), location: true)
            }
        }
        // A frame selects the native Adaptive writer, including its row path.
        let frame = FrameSnapshot(canvasSize: .init(width: 112, height: 88),
            photo: .init(x: 8, y: 8, width: 96, height: 64), paper: .init(repeating: 0.8))
        for rows in [true, false] {
            var request = env.request(.adaptive)
            request.allowsRowInput = rows
            let result = try await service.export(session: env.session.id, snapshot: env.snapshot(frame: frame), request: request)
            let output = try properties(result.file)
            try expectCapture(output, location: true)
            #expect(output[kCGImagePropertyPixelWidth] as? Int == 112)
            #expect(output[kCGImagePropertyPixelHeight] as? Int == 88)
            let source = try #require(CGImageSourceCreateWithURL(result.file as CFURL, nil))
            let hdr = try #require(CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
            #expect(hdr.contentHeadroom > 1)
        }
        var recipe = Recipe()
        recipe.setValue(.bool(false), for: "hdr.enabled")
        let sdr = try await service.export(session: env.session.id, snapshot: env.snapshot(recipe: recipe),
            request: env.request(.adaptive))
        try expectCapture(properties(sdr.file), location: true)
    }

    @Test func publishingDestinationRemovesOnlyLocation() async throws {
        let photo = try TinyPhoto(properties: captureProperties())
        let env = try await RecipeExportEnvironment(photo: photo); defer { env.remove() }
        let request = ExportPlanRequest(choice: .destination(.web),
            source: .init(domain: .sdr, pixelSize: .init(width: 96, height: 64)), edit: .init(peakStops: 2))
        let result = try await env.service().export(session: env.session.id, snapshot: env.snapshot(), request: request)
        try expectCapture(properties(result.file), location: false)
    }
}
