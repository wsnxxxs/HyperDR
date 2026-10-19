// What ImageIO -- and so Photos and Preview -- makes of an exported HDR file.
//
//     xcrun swiftc -O tests/hevc/imageio_probe.swift -o build/imageio_probe
//     build/imageio_probe FILE [--region X,Y,W,H]... [--exclude X,Y,W,H]...
//                              [--reference SDR_FILE]
//                              [--photo X,Y,W,H] [--gain-plane FILE --gain-bits 8|10 --chroma-support 0|3]
//
// Prints one JSON object:
//
// - `image`: type, size, bit depth, alpha, colour model, profile, orientation.
// - `gain_maps`: the ISO 21496-1 and Apple gain-map auxiliary images ImageIO
//   finds (size, pixel format, every XMP tag of the metadata it uses).
// - `jpeg_segments` (a JPEG file, by its bytes): every image in the file in order (primary,
//   then the gain-map JPEG) with its APP segment counts: XMP, ISO 21496-1,
//   MPF, ICC, Exif. Two XMP or two ISO segments in the gain map is the
//   defect E4 removes.
// - `hdr` / `sdr`: ImageIO's HDR decode at the file's full headroom (no
//   image-specific luma scaling, no tone mapping) and its SDR decode, as
//   linear extended Display P3: the peak channel value and peak luminance,
//   and the content headroom ImageIO reports.
// - With HYPERDR_PROBE_DUMP_HDR / HYPERDR_PROBE_DUMP_SDR set, those two decodes
//   are also written to the named files as raw float32 linear Display P3
//   (three uint32 width, height, 3, then RGB rows) for
//   tests/hevc/gain_map_metrics.cpp.
// - With HYPERDR_PROBE_DUMP_HDR_SIGNAL set, an HDR-only mode instead dumps
//   the decoded BT.2100 RGB signal in its own tagged PQ/HLG space. The metrics
//   helper inverts that transfer against the exact encoder input. No SDR
//   decode or ColorSync display OOTF participates in this codec-quality gate.
// - `regions`: for each `--region` (stored pixel coordinates, top-left
//   origin, before any Exif orientation) minus every `--exclude`, per channel:
//   log2(HDR / SDR) -- mean, maximum |·| and p99.9 |·| -- over the pixels whose
//   HDR and SDR values are both at least 0.02 (`bright_pixels`), and maximum |HDR - SDR|
//   over the darker ones (`dark_pixels`), where a ratio means nothing. A
//   frame L2 gate uses 0.05 stops at 8-bit, 0.03 at 10-bit outside c+r,
//   and dark differences <= one base code. p99.9 is the upper
//   edge of a 0.0001-stop bin, so zero gain reads 0.0001.
//   `sampled_pixels` counts the pixels measured; `valid` is false when it is
//   0 (the region lies outside the image, or the excludes cover it). A
//   statistic with nothing to measure is null, never 0: an empty region, or
//   the log2 figures of a channel with no bright pixel (an all-black mat is
//   measured by its dark figures alone). A consumer must treat null as a
//   failure, not as zero gain.
// - `reference` (with `--reference`): Y-PSNR between this file's SDR decode
//   and the reference's, on Display P3 encoded values (V3: >= 38 dB).
//
// Exit status: 0 printed; 1 the file (or the reference) cannot be decoded;
// 2 usage (a rectangle must be exactly four integers, width and height > 0,
//   and x + width and y + height must not overflow);
// 3 printed, but a region sampled no pixel (`valid: false`).

import CoreGraphics
import Foundation
import ImageIO
import CoreVideo

// Lightweight structural gate; no HDR reconstruction or large float buffers.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--require-iso-dimensions" {
    let args = CommandLine.arguments
    guard args.count == 5, let width = Int(args[2]), let height = Int(args[3]),
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == width, image.height == height,
          CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil else {
        FileHandle.standardError.write(Data("ImageIO dimensions/ISO auxiliary check failed\n".utf8))
        exit(1)
    }
    let result: [String: Any] = ["width": image.width, "height": image.height, "iso_auxiliary": true]
    let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)
    exit(0)
}

struct Rect {
    let x, y, width, height: Int

    /// Exactly four comma-separated integers; an empty or non-numeric field
    /// is an error, not skipped.
    init?(_ text: String) {
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        let parts = fields.map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, case let values = parts.compactMap({ $0 }), values.count == 4,
              values[2] > 0, values[3] > 0,
              !values[0].addingReportingOverflow(values[2]).overflow,
              !values[1].addingReportingOverflow(values[3]).overflow else { return nil }
        (x, y, width, height) = (values[0], values[1], values[2], values[3])
    }

    func contains(_ px: Int, _ py: Int) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }

    var json: [Int] { [x, y, width, height] }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
}

// --photo adds E5 L1/L2 per-ring statistics. k = actual chroma support +
// ceil(base/gain size ratio); the photo rectangle comes from the export report.
// HEIC raw gain samples come through the approved replaceable reader backend;
// JPEG samples are read directly from ImageIO auxiliary Data.

// MARK: - Arguments

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: imageio_probe FILE [--region X,Y,W,H]... [--exclude X,Y,W,H]... [--reference SDR_FILE]

        """.utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first, !path.hasPrefix("--") else { usage() }
arguments.removeFirst()
var regions: [Rect] = []
var excludes: [Rect] = []
var referencePath: String?
var photoRect: Rect?
var controlPath: String?
var gainPlanePath: String?
var gainBackend = "product-reader"
var gainBits = 8
var chromaSupport: Int?
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    guard let value = arguments.first else { usage() }
    arguments.removeFirst()
    switch flag {
    case "--region": guard let rect = Rect(value) else { usage() }; regions.append(rect)
    case "--exclude": guard let rect = Rect(value) else { usage() }; excludes.append(rect)
    case "--reference": referencePath = value
    case "--control": controlPath = value
    case "--photo": guard let rect = Rect(value) else { usage() }; photoRect = rect
    case "--gain-plane": gainPlanePath = value
    case "--gain-backend": gainBackend = value
    case "--gain-bits": guard let bits = Int(value), [8,10].contains(bits) else { usage() }; gainBits = bits
    case "--chroma-support": guard let c = Int(value), [0,3].contains(c) else { usage() }; chromaSupport = c
    default: usage()
    }
}

// MARK: - Decoding

/// Linear extended Display P3 for ratios; encoded Display P3 for PSNR.
let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let encodedSpace = CGColorSpace(name: CGColorSpace.displayP3)!

struct Pixels {
    let width, height: Int
    /// RGBA float, rows top first.
    let values: [Float]

    subscript(x: Int, y: Int, channel: Int) -> Float { values[(y * width + x) * 4 + channel] }
}

func source(_ path: String) throws -> CGImageSource {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else { throw Failure(description: "cannot open \(path)") }
    return source
}

/// ImageIO's decode of the first image: the HDR rendition at the file's full
/// headroom, or the SDR one.
func decode(_ source: CGImageSource, hdr: Bool) throws -> CGImage {
    let options: [CFString: Any] = [
        kCGImageSourceDecodeRequest: hdr ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR,
        // The file's own gain, not a tone curve fitted to it.
        kCGImageSourceGenerateImageSpecificLumaScaling: false,
        kCGImageSourceShouldCache: false,
    ]
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
        throw Failure(description: "ImageIO cannot decode the \(hdr ? "HDR" : "SDR") rendition")
    }
    return image
}

func render(_ image: CGImage, in space: CGColorSpace) throws -> Pixels {
    let width = image.width, height = image.height
    var values = [Float](repeating: 0, count: width * height * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    try values.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                      bytesPerRow: width * 16, space: space, bitmapInfo: info) else {
            throw Failure(description: "cannot create a \(width) × \(height) float context")
        }
        // Headroom unknown: draw the values as they are, without tone mapping.
        _ = context.setEDRTargetHeadroom(0)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return Pixels(width: width, height: height, values: values)
}

// MARK: - File structure

func imageFacts(_ source: CGImageSource) -> [String: Any] {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    var facts: [String: Any] = [
        "type": CGImageSourceGetType(source) as String? ?? "unknown",
        "image_count": CGImageSourceGetCount(source),
    ]
    let keys: [(CFString, String)] = [
        (kCGImagePropertyPixelWidth, "width"), (kCGImagePropertyPixelHeight, "height"),
        (kCGImagePropertyDepth, "bit_depth"), (kCGImagePropertyHasAlpha, "has_alpha"),
        (kCGImagePropertyColorModel, "color_model"), (kCGImagePropertyProfileName, "profile"),
        (kCGImagePropertyOrientation, "orientation"),
    ]
    for (key, name) in keys {
        if let value = properties[key] { facts[name] = jsonValue(value) }
    }
    return facts
}

/// Every tag of an auxiliary image's metadata, by path ("hdrgm:HDRCapacityMax").
func metadataTags(_ metadata: CGImageMetadata) -> [String: Any] {
    var tags: [String: Any] = [:]
    let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
    CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, options) { path, tag in
        if let value = CGImageMetadataTagCopyValue(tag), !(value is [Any]), !(value is [String: Any]) {
            tags[path as String] = jsonValue(value)
        }
        return true
    }
    return tags
}

func gainMaps(_ source: CGImageSource) -> [String: Any] {
    var maps: [String: Any] = [:]
    for (type, name) in [(kCGImageAuxiliaryDataTypeISOGainMap, "iso"), (kCGImageAuxiliaryDataTypeHDRGainMap, "apple")] {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [CFString: Any] else {
            maps[name] = NSNull()
            continue
        }
        var map: [String: Any] = [:]
        if let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any] {
            map["description"] = description.mapValues(jsonValue)
        }
        if let data = info[kCGImageAuxiliaryDataInfoData] as? Data { map["bytes"] = data.count }
        if let metadata = info[kCGImageAuxiliaryDataInfoMetadata] {
            map["metadata"] = metadataTags(metadata as! CGImageMetadata)
        }
        maps[name] = map
    }
    return maps
}

/// The images in a JPEG file and their APP segments: the primary image, then
/// any appended ones (the Ultra HDR gain map), found by walking each image's
/// markers to its end of image.
func jpegSegments(_ data: Data) -> [[String: Any]] {
    let bytes = [UInt8](data)
    let n = bytes.count
    var images: [[String: Any]] = []
    var i = 0
    func has(_ signature: String, at offset: Int, length: Int) -> Bool {
        let signature = Array(signature.utf8)
        return length >= signature.count && offset + signature.count <= n
            && Array(bytes[offset..<offset + signature.count]) == signature
    }
    while i + 1 < n {
        guard bytes[i] == 0xFF, bytes[i + 1] == 0xD8 else { i += 1; continue }
        let start = i
        var counts = ["xmp": 0, "xmp_extended": 0, "iso_21496": 0, "mpf": 0, "icc": 0, "exif": 0]
        var j = i + 2
        var ended = false
        // Markers up to the start of scan.
        while j + 1 < n {
            guard bytes[j] == 0xFF else { j += 1; continue }
            let marker = bytes[j + 1]
            if marker == 0xFF { j += 1; continue }
            if marker == 0xD9 { j += 2; ended = true; break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { j += 2; continue }
            guard j + 3 < n else { j = n; break }
            let length = Int(bytes[j + 2]) << 8 | Int(bytes[j + 3])
            let payload = j + 4, size = length - 2
            switch marker {
            case 0xE1:
                if has("http://ns.adobe.com/xap/1.0/\0", at: payload, length: size) { counts["xmp", default: 0] += 1 }
                if has("http://ns.adobe.com/xmp/extension/\0", at: payload, length: size) {
                    counts["xmp_extended", default: 0] += 1
                }
                if has("Exif\0\0", at: payload, length: size) { counts["exif", default: 0] += 1 }
            case 0xE2:
                if has("urn:iso:std:iso:ts:21496:-1\0", at: payload, length: size) { counts["iso_21496", default: 0] += 1 }
                if has("MPF\0", at: payload, length: size) { counts["mpf", default: 0] += 1 }
                if has("ICC_PROFILE\0", at: payload, length: size) { counts["icc", default: 0] += 1 }
            default:
                break
            }
            j = payload + size
            if marker == 0xDA {
                // Entropy-coded data: the next marker that is not a stuffed
                // zero or a restart ends it.
                while j + 1 < n {
                    if bytes[j] == 0xFF, bytes[j + 1] != 0x00, !(0xD0...0xD7).contains(bytes[j + 1]) { break }
                    j += 1
                }
            }
        }
        var image: [String: Any] = ["offset": start, "length": j - start, "complete": ended]
        for (key, count) in counts { image[key] = count }
        images.append(image)
        i = max(j, start + 2)
    }
    return images
}

// MARK: - Measurements

func peaks(_ pixels: Pixels) -> [String: Any] {
    var peak: Float = 0, luminance: Float = 0
    var channels: [Float] = [0, 0, 0]
    for p in stride(from: 0, to: pixels.values.count, by: 4) {
        let r = pixels.values[p], g = pixels.values[p + 1], b = pixels.values[p + 2]
        channels[0] = max(channels[0], r)
        channels[1] = max(channels[1], g)
        channels[2] = max(channels[2], b)
        peak = max(peak, r, g, b)
        // Display P3 luminance coefficients.
        luminance = max(luminance, 0.2289746 * r + 0.6917385 * g + 0.0792869 * b)
    }
    return ["peak": Double(peak), "peak_channels": channels.map(Double.init), "peak_luminance": Double(luminance)]
}

/// |log2 ratio| histogram: 0.0001-stop bins up to 16 stops, the rest in the last.
struct RatioStats {
    static let binWidth = 0.0001
    var bins = [Int](repeating: 0, count: 160_001)
    var count = 0, sum = 0.0, maximum = 0.0
    var darkCount = 0
    var darkMaximum = 0.0

    mutating func add(hdr: Float, sdr: Float) {
        if sdr < 0.02 || hdr < 0.02 {
            darkCount += 1
            darkMaximum = max(darkMaximum, Double(abs(hdr - sdr)))
            return
        }
        let ratio = log2(Double(max(hdr, 1e-9)) / Double(sdr))
        count += 1
        sum += ratio
        maximum = max(maximum, abs(ratio))
        bins[min(Int(abs(ratio) / Self.binWidth), bins.count - 1)] += 1
    }

    func percentile(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let target = Int((Double(count) * fraction).rounded(.up))
        var seen = 0
        for (bin, n) in bins.enumerated() {
            seen += n
            if seen >= target { return Double(bin + 1) * Self.binWidth }
        }
        return maximum
    }

    /// Null where there was nothing to measure.
    var json: [String: Any] {
        let none = NSNull()
        return ["bright_pixels": count, "dark_pixels": darkCount,
                "mean_log2": count > 0 ? sum / Double(count) : none,
                "max_abs_log2": count > 0 ? maximum : none,
                "p99_abs_log2": count > 0 ? percentile(0.99) : none,
                "p999_abs_log2": count > 0 ? percentile(0.999) : none,
                "dark_max_abs_diff": darkCount > 0 ? darkMaximum : none]
    }
}

func measure(_ region: Rect, excluding excludes: [Rect], hdr: Pixels, sdr: Pixels) -> [String: Any] {
    var stats = [RatioStats(), RatioStats(), RatioStats()]
    var peak: Float = 0
    var sampled = 0
    let x0 = max(region.x, 0), y0 = max(region.y, 0)
    let x1 = min(region.x + region.width, hdr.width), y1 = min(region.y + region.height, hdr.height)
    if x0 < x1, y0 < y1 {
        for y in y0..<y1 {
            for x in x0..<x1 where !excludes.contains(where: { $0.contains(x, y) }) {
                sampled += 1
                for c in 0..<3 {
                    let h = hdr[x, y, c]
                    stats[c].add(hdr: h, sdr: sdr[x, y, c])
                    peak = max(peak, h)
                }
            }
        }
    }
    return ["rect": region.json, "excluded": excludes.map(\.json), "sampled_pixels": sampled,
            "valid": sampled > 0, "hdr_peak": sampled > 0 ? Double(peak) : NSNull(),
            "channels": sampled > 0 ? stats.map(\.json) : NSNull()]
}

func yPSNR(_ a: Pixels, _ b: Pixels) throws -> Double {
    guard a.width == b.width, a.height == b.height else {
        throw Failure(description: "reference is \(b.width) × \(b.height), file is \(a.width) × \(a.height)")
    }
    var squared = 0.0
    for p in stride(from: 0, to: a.values.count, by: 4) {
        let ya = 0.2126 * clamp(a.values[p]) + 0.7152 * clamp(a.values[p + 1]) + 0.0722 * clamp(a.values[p + 2])
        let yb = 0.2126 * clamp(b.values[p]) + 0.7152 * clamp(b.values[p + 1]) + 0.0722 * clamp(b.values[p + 2])
        squared += (ya - yb) * (ya - yb)
    }
    let mse = squared / Double(a.width * a.height)
    return mse == 0 ? 999 : 10 * log10(1 / mse)
}

func clamp(_ value: Float) -> Double { Double(min(max(value, 0), 1)) }


// E5: L1 and L2 share the same photo rectangle supplied by the export report.
// L1 uses raw auxiliary samples; it never infers gain from HDR/SDR ratios.
struct GainSamples {
    let width, height, channels, bits: Int
    let values: [Float]
    let metadata: [[Double]] // min, max, gamma
    let backend: String
}
func gainSamples(_ file: CGImageSource) throws -> GainSamples {
    guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(file,0,kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString:Any],
          let desc = info[kCGImageAuxiliaryDataInfoDataDescription] as? [String:Any],
          let metadata = info[kCGImageAuxiliaryDataInfoMetadata],
          let width = (desc["Width"] as? NSNumber)?.intValue,
          let height = (desc["Height"] as? NSNumber)?.intValue else {
        throw Failure(description:"missing ISO gain-map description/metadata")
    }
    let tags = metadataTags(metadata as! CGImageMetadata)
    var channels = 1
    if tags["HDRToneMap:ChannelMetadata[2].GainMapMin"] != nil { channels = 3 }
    var ranges = [[Double]]()
    for c in 0..<channels {
        var fields = [Double]()
        for field in ["GainMapMin","GainMapMax","Gamma"] {
            guard let text = tags["HDRToneMap:ChannelMetadata[\(c)].\(field)"] as? String,
                  let number = Double(text), number.isFinite else { throw Failure(description:"missing gain range") }
            fields.append(number)
        }
        guard fields[1] >= fields[0], fields[2] > 0 else { throw Failure(description:"invalid gain range") }
        ranges.append(fields)
    }
    if info[kCGImageAuxiliaryDataInfoData] as? Data == nil, let gainPlanePath {
        let data = try Data(contentsOf:URL(fileURLWithPath:gainPlanePath))
        guard data.count >= 12 else { throw Failure(description:"short gain plane") }
        let shape = data.prefix(12).withUnsafeBytes { Array($0.bindMemory(to:UInt32.self)) }
        guard shape == [UInt32(width),UInt32(height),UInt32(channels)], data.count == 12+width*height*channels*4 else {
            throw Failure(description:"ImageIO and gain reader dimensions disagree")
        }
        let values = data.dropFirst(12).withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw Failure(description:"invalid raw gain code") }
        return GainSamples(width:width,height:height,channels:channels,bits:gainBits,values:values,
                           metadata:ranges,backend:gainBackend)
    }
    guard let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
          let stride = (desc["BytesPerRow"] as? NSNumber)?.intValue,
          let format = (desc["PixelFormat"] as? NSNumber)?.uint32Value else {
        throw Failure(description:"ImageIO auxiliary has no raw Data; supply the approved product gain-plane backend")
    }
    let components: Int
    switch format {
    case kCVPixelFormatType_OneComponent8: components = 1
    case kCVPixelFormatType_24RGB: components = 3
    case kCVPixelFormatType_32RGBA, kCVPixelFormatType_32BGRA: components = 4
    default: throw Failure(description:"unsupported ImageIO gain pixel format \(format)")
    }
    guard stride >= width*components, data.count >= stride*height else { throw Failure(description:"short auxiliary Data") }
    var values = [Float](); values.reserveCapacity(width*height*channels)
    for y in 0..<height { for x in 0..<width { for c in 0..<channels {
        let channel = components == 1 ? 0 : (format == kCVPixelFormatType_32BGRA ? 2-c : c)
        values.append(Float(data[y*stride+x*components+channel])/255)
    } } }
    return GainSamples(width:width,height:height,channels:channels,bits:8,values:values,metadata:ranges,backend:"imageio-data")
}
struct GainStats {
    var samples = [Double]()
    var zeroPixels = 0
    var point = [Int]()
    var maximum = 0.0
    mutating func add(_ stops: Double, zero: Bool, x: Int, y: Int) {
        samples.append(abs(stops)); if zero { zeroPixels += 1 }
        if point.isEmpty || abs(stops) > maximum { maximum = abs(stops); point = [x,y] }
    }
    var json: [String:Any] {
        let sorted = samples.sorted()
        return ["samples":samples.count,"valid":!samples.isEmpty,"max_abs_stops":maximum,
                "p99_abs_stops":sorted.isEmpty ? NSNull() : sorted[min(sorted.count-1,Int(ceil(Double(sorted.count)*0.99))-1)],
                "zero_fraction":samples.isEmpty ? NSNull() : Double(zeroPixels)/Double(samples.count),"maximum_point":point]
    }
}
func frameRings(_ rect: Rect, file: CGImageSource, hdr: Pixels, sdr: Pixels, control: Pixels?, bytes: Data) throws -> [String:Any] {
    let gain = try gainSamples(file)
    let c: Int
    if let chromaSupport { c = chromaSupport }
    else {
        // Read the JPEG SOF component sampling factors, not its file extension.
        let raw = [UInt8](bytes); var i = 2; var found: Int?
        while i+11 < raw.count {
            guard raw[i] == 255 else { throw Failure(description:"invalid JPEG marker") }
            let marker = raw[i+1], length = Int(raw[i+2])*256+Int(raw[i+3])
            if [UInt8(0xC0),0xC1,0xC2].contains(marker) {
                let sampling = raw[i+11]
                guard sampling == 0x22 || sampling == 0x11 else { throw Failure(description:"unsupported JPEG chroma support") }
                found = sampling == 0x22 ? 3 : 0; break
            }
            if marker == 0xDA || length < 2 { break }; i += 2+length
        }
        guard let found else { throw Failure(description:"cannot read base chroma sampling") }; c = found
    }
    let ratio = max(Double(hdr.width)/Double(gain.width), Double(hdr.height)/Double(gain.height))
    let k = c + Int(ceil(ratio))
    var l1 = [GainStats](repeating:GainStats(),count:k+1)
    var l2 = (0...k).map { _ in [RatioStats(),RatioStats(),RatioStats()] }
    var residual = (0...k).map { _ in [RatioStats(),RatioStats(),RatioStats()] }
    var points = [[Int]](repeating:[],count:k+1)
    var maximums = [Double](repeating:-1,count:k+1)
    var values = [[Float]](repeating:[],count:k+1)
    var near = GainStats(), far = GainStats()
    let levels = Double((1<<gain.bits)-1)
    for y in 0..<hdr.height { for x in 0..<hdr.width {
        let distance = max(rect.x-x, x-(rect.x+rect.width-1), rect.y-y, y-(rect.y+rect.height-1))
        if distance <= 0 { continue }
        let ring = distance <= k ? distance-1 : k
        // Gain layer statistics sample native codes. For a smaller constant
        // map, all corresponding base pixels map to that same native zero code.
        let gx = min(gain.width-1,x*gain.width/hdr.width), gy = min(gain.height-1,y*gain.height/hdr.height)
        var stops = 0.0, zero = true
        for channel in 0..<gain.channels {
            let m = gain.metadata[channel]
            let code = Double(gain.values[(gy*gain.width+gx)*gain.channels+channel])
            let decoded = m[0]+(m[1]-m[0])*pow(code,1/m[2])
            stops = max(stops,abs(decoded))
            let zeroCode = (m[1]>m[0]) ? pow(max(0,min(1,-m[0]/(m[1]-m[0]))),m[2])*levels : 0
            zero = zero && Int((code*levels).rounded()) == Int(zeroCode.rounded())
        }
        l1[ring].add(stops,zero:zero,x:x,y:y)
        if distance <= 8 { near.add(stops,zero:zero,x:x,y:y) } else { far.add(stops,zero:zero,x:x,y:y) }
        for channel in 0..<3 {
            let h = hdr[x,y,channel], s = sdr[x,y,channel]
            guard h.isFinite && s.isFinite else { throw Failure(description:"nonfinite decoded frame pixel") }
            l2[ring][channel].add(hdr:h,sdr:s)
            if let control { residual[ring][channel].add(hdr:h,sdr:control[x,y,channel]) }
            if h>=0.02 && s>=0.02 {
                let delta = abs(log2(Double(h)/Double(s)))
                if delta > maximums[ring] { maximums[ring]=delta;points[ring]=[x,y,channel];values[ring]=[h,s] }
            }
        }
    } }
    return ["photo":rect.json,"k":k,"base_chroma_support":c,"gain_scale":ratio,
            "gain_width":gain.width,"gain_height":gain.height,"gain_bits":gain.bits,"gain_backend":gain.backend,
            "l1_near8":near.json,"l1_far8":far.json,
            "rings":(0...k).map { i -> [String:Any] in
                ["distance":i<k ? String(i+1) : ">\(k)","l1":l1[i].json,
                 "l2":l2[i].map(\.json),"control_l2":residual[i].map(\.json),"maximum_point":points[i],"maximum_hdr_sdr":values[i]]
            }]
}

// MARK: - JSON

func jsonValue(_ value: Any) -> Any {
    switch value {
    case let number as NSNumber:
        return number.doubleValue.isFinite ? number : NSNull()
    case let string as String:
        return string
    case let array as [Any]:
        return array.map(jsonValue)
    case let dictionary as [String: Any]:
        return dictionary.mapValues(jsonValue)
    default:
        return String(describing: value)
    }
}

func finite(_ value: Any) -> Any {
    switch value {
    case let number as Double: return number.isFinite ? number : NSNull()
    case let array as [Any]: return array.map(finite)
    case let dictionary as [String: Any]: return dictionary.mapValues(finite)
    default: return value
    }
}

// MARK: - Main

do {
    let file = try source(path)
    var report: [String: Any] = ["path": path, "image": imageFacts(file), "gain_maps": gainMaps(file)]
    // By the bytes, not ImageIO's type: it reports an Ultra HDR JPEG as
    // public.heic on macOS 27.
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
        report["jpeg_segments"] = jpegSegments(bytes)
    }
    let hdrImage = try decode(file, hdr: true)
    // Codec quality uses ImageIO's HDR-decoded signal in its own tagged colour
    // space. Apply the specified PQ/HLG transfer explicitly in the metrics
    // helper; a ColorSync HLG display conversion has its own viewing OOTF.
    if let output = ProcessInfo.processInfo.environment["HYPERDR_PROBE_DUMP_HDR_SIGNAL"] {
        guard let space = hdrImage.colorSpace,
              space.name == CGColorSpace.itur_2100_PQ || space.name == CGColorSpace.itur_2100_HLG else {
            throw Failure(description: "HDR signal is not tagged BT.2100 PQ or HLG")
        }
        let signal = try render(hdrImage, in: space)
        let shape = [UInt32(signal.width), UInt32(signal.height), UInt32(3)]
        var data = shape.withUnsafeBytes { Data($0) }
        var rgb = [Float]()
        for i in stride(from: 0, to: signal.values.count, by: 4) { rgb.append(contentsOf: signal.values[i..<i+3]) }
        rgb.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: URL(fileURLWithPath: output))
        report["hdr_signal_space"] = space.name! as String
        let json = try JSONSerialization.data(withJSONObject: finite(report), options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(json)
        exit(0) // HDR-only mode never requests a tone-mapped SDR rendition.
    }
    let sdrImage = try decode(file, hdr: false)
    let hdr = try render(hdrImage, in: linearSpace)
    let sdr = try render(sdrImage, in: linearSpace)
    for (key, pixels) in [("HYPERDR_PROBE_DUMP_HDR", hdr), ("HYPERDR_PROBE_DUMP_SDR", sdr)] {
        guard let output = ProcessInfo.processInfo.environment[key] else { continue }
        let shape = [UInt32(pixels.width), UInt32(pixels.height), UInt32(3)]
        var data = shape.withUnsafeBytes { Data($0) }
        var rgb = [Float](); rgb.reserveCapacity(pixels.width * pixels.height * 3)
        for i in stride(from: 0, to: pixels.values.count, by: 4) {
            rgb.append(pixels.values[i]); rgb.append(pixels.values[i+1]); rgb.append(pixels.values[i+2])
        }
        rgb.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: URL(fileURLWithPath: output))
    }
    report["hdr"] = peaks(hdr).merging(["content_headroom": Double(hdrImage.contentHeadroom)]) { a, _ in a }
    report["sdr"] = peaks(sdr).merging(["content_headroom": Double(sdrImage.contentHeadroom)]) { a, _ in a }
    if hdr.width != sdr.width || hdr.height != sdr.height {
        throw Failure(description: "HDR decode is \(hdr.width) × \(hdr.height), SDR \(sdr.width) × \(sdr.height)")
    }
    if let photoRect {
        var control: Pixels?
        if let controlPath {
            let controlFile = try source(controlPath)
            control = try render(decode(controlFile,hdr:true),in:linearSpace)
            guard control!.width == hdr.width && control!.height == hdr.height else { throw Failure(description:"control dimensions differ") }
            report["control_gain_maps"] = gainMaps(controlFile)
        }
        report["frame_rings"] = try frameRings(photoRect,file:file,hdr:hdr,sdr:sdr,control:control,bytes:bytes)
    }
    let measured = regions.map { measure($0, excluding: excludes, hdr: hdr, sdr: sdr) }
    report["regions"] = measured
    if let referencePath {
        let reference = try render(decode(try source(referencePath), hdr: false), in: encodedSpace)
        let own = try render(sdrImage, in: encodedSpace)
        report["reference"] = ["path": referencePath, "y_psnr_db": try yPSNR(own, reference)]
    }
    let data = try JSONSerialization.data(withJSONObject: finite(report), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    let empty = zip(regions, measured).filter { $0.1["valid"] as? Bool != true }.map { $0.0.json }
    if !empty.isEmpty {
        FileHandle.standardError.write(Data("imageio_probe: no pixel sampled in region(s) \(empty)\n".utf8))
        exit(3)
    }
} catch {
    FileHandle.standardError.write(Data("imageio_probe: \(error)\n".utf8))
    exit(1)
}
