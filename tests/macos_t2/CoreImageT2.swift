import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct Rational: Decodable {
    let numerator: Int
    let denominator: Int
}

struct Fixture: Decodable {
    let id: String
    let path: String
    let gamma: Rational
}

struct FixtureManifest: Decodable {
    let protocol_id: String
    let fixtures: [Fixture]
}

enum HarnessError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

func integerExtent(_ extent: CGRect, label: String) throws -> (Int, Int) {
    let width = Int(extent.width.rounded())
    let height = Int(extent.height.rounded())
    guard width > 0, height > 0,
          abs(extent.width - CGFloat(width)) < 0.0001,
          abs(extent.height - CGFloat(height)) < 0.0001 else {
        throw HarnessError.message("\(label) has non-integral or empty extent: \(extent)")
    }
    return (width, height)
}

func renderRGB(
    _ image: CIImage,
    context: CIContext,
    colorSpace: CGColorSpace?,
    label: String
) throws -> [Float] {
    let (width, height) = try integerExtent(image.extent, label: label)
    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { storage in
        context.render(
            image,
            toBitmap: storage.baseAddress!,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: image.extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }
    var rgb = [Float]()
    rgb.reserveCapacity(width * height * 3)
    for index in 0..<(width * height) {
        for channel in 0..<3 {
            let value = rgba[index * 4 + channel]
            guard value.isFinite else {
                throw HarnessError.message("\(label) produced a non-finite pixel")
            }
            rgb.append(value)
        }
    }
    return rgb
}

func renderGain(_ image: CIImage, context: CIContext) throws -> [Float] {
    let (width, height) = try integerExtent(image.extent, label: "gain map")
    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { storage in
        context.render(
            image,
            toBitmap: storage.baseAddress!,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: image.extent,
            format: .RGBAf,
            colorSpace: nil
        )
    }
    var gain = [Float]()
    gain.reserveCapacity(width * height)
    for index in 0..<(width * height) {
        let value = rgba[index * 4]
        guard value.isFinite else {
            throw HarnessError.message("gain map produced a non-finite pixel")
        }
        gain.append(value)
    }
    return gain
}

func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

func appendFloatLE(_ value: Float, to data: inout Data) {
    appendUInt32LE(value.bitPattern, to: &data)
}

func writeInputBundle(
    path: URL,
    baseWidth: Int,
    baseHeight: Int,
    gainWidth: Int,
    gainHeight: Int,
    base: [Float],
    gain: [Float]
) throws {
    guard base.count == baseWidth * baseHeight * 3,
          gain.count == gainWidth * gainHeight else {
        throw HarnessError.message("decoded input dimensions disagree with their buffers")
    }
    var data = Data("HDT2IN01".utf8)
    for value in [baseWidth, baseHeight, gainWidth, gainHeight] {
        guard let exact = UInt32(exactly: value) else {
            throw HarnessError.message("decoded input dimension exceeds UInt32")
        }
        appendUInt32LE(exact, to: &data)
    }
    for value in base { appendFloatLE(value, to: &data) }
    for value in gain { appendFloatLE(value, to: &data) }
    try data.write(to: path, options: .atomic)
}

func architectureName() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

func run() throws {
    guard #available(macOS 15.0, *) else {
        throw HarnessError.message("T2 requires macOS 15 or newer")
    }
    guard CommandLine.arguments.count == 5 else {
        throw HarnessError.message(
            "usage: CoreImageT2 <fixture-manifest.json> <fixture-spec.json> <output-dir> <report.json>"
        )
    }
    let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let specURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let reportURL = URL(fileURLWithPath: CommandLine.arguments[4])
    let decoder = JSONDecoder()
    let manifest = try decoder.decode(FixtureManifest.self, from: Data(contentsOf: manifestURL))
    let specObject = try JSONSerialization.jsonObject(with: Data(contentsOf: specURL))
    guard let spec = specObject as? [String: Any],
          let headroomValues = spec["physical_headroom_stops"] as? [NSNumber],
          (3...5).contains(headroomValues.count) else {
        throw HarnessError.message("fixture spec must contain three to five headroom nodes")
    }
    let headrooms = headroomValues.map { Float(truncating: $0) }
    guard headrooms[0] > 0, headrooms.last! < 2,
          zip(headrooms, headrooms.dropFirst()).allSatisfy({ $0 < $1 }) else {
        throw HarnessError.message("headroom nodes must be ordered, distinct, and interior to (0,2) stops")
    }
    try FileManager.default.createDirectory(
        at: outputURL, withIntermediateDirectories: true, attributes: nil
    )
    guard let linearP3 = CGColorSpace(name: CGColorSpace.linearDisplayP3) else {
        throw HarnessError.message("linear Display P3 color space is unavailable")
    }
    let context = CIContext(options: [
        .useSoftwareRenderer: true,
        .workingColorSpace: linearP3,
        .outputColorSpace: linearP3,
        .cacheIntermediates: false,
    ])
    var fixtureReports = [[String: Any]]()
    let fixtureRoot = manifestURL.deletingLastPathComponent()
    for fixture in manifest.fixtures {
        let fileURL = fixtureRoot.appendingPathComponent(fixture.path)
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw HarnessError.message("ImageIO rejected \(fixture.id)")
        }
        let isoAuxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap
        )
        guard isoAuxiliary != nil else {
            throw HarnessError.message("ImageIO did not expose the ISO gain map for \(fixture.id)")
        }
        guard let base = CIImage(
            contentsOf: fileURL,
            options: [.applyOrientationProperty: false, .expandToHDR: false]
        ) else {
            throw HarnessError.message("Core Image could not load the SDR base for \(fixture.id)")
        }
        guard let gain = CIImage(
            contentsOf: fileURL,
            options: [.applyOrientationProperty: false, .auxiliaryHDRGainMap: true]
        ) else {
            throw HarnessError.message("Core Image could not load the gain map for \(fixture.id)")
        }
        guard !gain.properties.isEmpty else {
            throw HarnessError.message("gain-map recipe metadata is missing for \(fixture.id)")
        }
        let (baseWidth, baseHeight) = try integerExtent(base.extent, label: "SDR base")
        let (gainWidth, gainHeight) = try integerExtent(gain.extent, label: "gain map")
        guard baseWidth > gainWidth, baseHeight > gainHeight else {
            throw HarnessError.message("T2 fixture does not exercise gain-map upsampling")
        }
        let basePixels = try renderRGB(
            base, context: context, colorSpace: linearP3, label: "SDR base"
        )
        let gainPixels = try renderGain(gain, context: context)
        let bundleName = "\(fixture.id)-decoded-input.bin"
        try writeInputBundle(
            path: outputURL.appendingPathComponent(bundleName),
            baseWidth: baseWidth,
            baseHeight: baseHeight,
            gainWidth: gainWidth,
            gainHeight: gainHeight,
            base: basePixels,
            gain: gainPixels
        )

        let scaleX = base.extent.width / gain.extent.width
        let scaleY = base.extent.height / gain.extent.height
        let translationX = base.extent.minX - gain.extent.minX * scaleX
        let translationY = base.extent.minY - gain.extent.minY * scaleY
        let transform = CGAffineTransform(
            a: scaleX, b: 0, c: 0, d: scaleY,
            tx: translationX, ty: translationY
        )
        // clampedToExtent before sampling: outside its extent a CIImage is
        // transparent black, so an unclamped bilinear tap at the border blends
        // gain code zero into the edge row and column, while reconstruct.cpp
        // clamps to the edge sample. A border disagreement caused by that would
        // be charged to the interpolation question it has nothing to do with.
        let scaledGain = gain
            .clampedToExtent()
            .samplingLinear()
            .transformed(by: transform)
            .cropped(to: base.extent)
        guard scaledGain.extent == base.extent else {
            throw HarnessError.message("scaled gain extent does not match the SDR base")
        }
        guard !scaledGain.properties.isEmpty else {
            throw HarnessError.message("gain-map recipe metadata was lost during scaling")
        }
        var nodes = [[String: Any]]()
        for stops in headrooms {
            let linearHeadroom = powf(2, stops)
            let rendered = base.applyingGainMap(scaledGain, headroom: linearHeadroom)
            let pixels = try renderRGB(
                rendered,
                context: context,
                colorSpace: linearP3,
                label: "Core Image rendered output"
            )

            // The judged path above hands Core Image a gain map this harness has
            // already resampled, which settles the interpolation order by
            // construction: codes are interpolated here, then decoded there. It
            // can confirm the decode formula and the weight semantics; it cannot
            // say what Apple's decoder does when Apple is the one upsampling.
            // This second path hands over the native-resolution gain map, which
            // is the only way the registered question gets asked at all. It is
            // recorded and never judged here: no decision rule for it has been
            // registered, and inventing one after seeing the numbers is exactly
            // what pre-registration exists to prevent.
            var nativeRecord: [String: Any]
            let nativeRendered = base.applyingGainMap(gain, headroom: linearHeadroom)
            if nativeRendered.extent != base.extent {
                nativeRecord = [
                    "available": false,
                    "reason": "rendered extent \(nativeRendered.extent) is not the base extent",
                ]
            } else if let nativePixels = try? renderRGB(
                nativeRendered, context: context, colorSpace: linearP3,
                label: "Core Image native-gain output"
            ) {
                nativeRecord = ["available": true, "rgb": nativePixels.map(Double.init)]
            } else {
                nativeRecord = ["available": false, "reason": "render failed"]
            }

            nodes.append([
                "physical_headroom_stops": Double(stops),
                "linear_headroom_passed_to_core_image": Double(linearHeadroom),
                "rgb": pixels.map(Double.init),
                "core_image_upsampled_gain": nativeRecord,
            ])
        }

        // A third path with no harness geometry in it at all: ask ImageIO and
        // Core Image to expand the file themselves. Whatever comes out is
        // Apple's pipeline end to end, at the headroom the file declares.
        var expandedRecord: [String: Any] = [
            "available": false,
            "reason": "expandToHDR did not yield a base-sized image",
        ]
        if let hdr = CIImage(
            contentsOf: fileURL,
            options: [.applyOrientationProperty: false, .expandToHDR: true]
        ), hdr.extent == base.extent,
           let hdrPixels = try? renderRGB(
               hdr, context: context, colorSpace: linearP3, label: "expandToHDR output"
           ) {
            expandedRecord = ["available": true, "rgb": hdrPixels.map(Double.init)]
        }

        fixtureReports.append([
            "id": fixture.id,
            "gamma": Double(fixture.gamma.numerator) / Double(fixture.gamma.denominator),
            "imageio_source_count": CGImageSourceGetCount(imageSource),
            "imageio_iso_gain_map_present": true,
            "gain_properties_present": true,
            "base_width": baseWidth,
            "base_height": baseHeight,
            "gain_width": gainWidth,
            "gain_height": gainHeight,
            "decoded_input_bundle": bundleName,
            "nodes": nodes,
            "expand_to_hdr": expandedRecord,
        ])
    }
    let report: [String: Any] = [
        "schema_version": 1,
        "protocol_id": manifest.protocol_id,
        "renderer": "Core Image CIImage.applyingGainMap(_:headroom:)",
        "renderer_configuration": [
            "software_renderer": true,
            "working_and_output_color_space": "linear Display P3",
            "gain_scaling": "Core Image affine transform from native gain extent to base extent",
        ],
        "platform": [
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architectureName(),
        ],
        "fixtures": fixtureReports,
    ]
    let reportData = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try reportData.write(to: reportURL, options: .atomic)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("macOS T2 Core Image failure: \(error)\n".utf8))
    exit(1)
}
