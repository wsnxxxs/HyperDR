// Develop a RAW file the way HyperDRRender's SourceLoader does, into a float TIFF.
//
//     swiftc -O HyperDR_Model/denoise/develop_raw.swift -o build/denoise/develop_raw
//     build/denoise/develop_raw in.arw out.tiff [--boost 0|1] [--apple-nr] [--scale s] [--decoder 8|9] [--luma l]
//
// Defaults match `SourceOptions.sceneLinear`: boost 0, exposure 0, extended range
// on, gamut mapping off, contrast and local tone map 0, the file's baseline
// exposure kept. Apple's luminance/colour noise reduction and sharpening are set
// to 0 unless --apple-nr is given (then the camera defaults stay), so the output
// carries the sensor noise a learned denoiser would see. --luma sets the luminance NR
// amount after that (decoder 9 runs its own learned processing whatever it is). Pixels are extended
// linear Display P3, RGBA float32, oriented. A JSON line with the development
// facts goes to stdout.

import CoreImage
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func number(_ text: String) -> Float {
    guard let value = Float(text) else { fail("not a number: \(text)") }
    return value
}

var arguments = Array(CommandLine.arguments.dropFirst())
var boost: Float = 0
var appleNR = false
var scale: Float = 1
var decoder: String? = nil
var luma: Float? = nil
var positional: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--boost": boost = number(arguments.removeFirst())
    case "--apple-nr": appleNR = true
    case "--scale": scale = number(arguments.removeFirst())
    case "--decoder": decoder = arguments.removeFirst()
    case "--luma": luma = number(arguments.removeFirst())
    default: positional.append(argument)
    }
}
guard positional.count == 2 else { fail("usage: develop_raw in out.tiff [--boost b] [--apple-nr] [--scale s] [--decoder 8|9] [--luma l]") }
let input = URL(fileURLWithPath: positional[0]), output = URL(fileURLWithPath: positional[1])

guard let filter = CIRAWFilter(imageURL: input) else { fail("cannot open \(input.path)") }
if let decoder {
    guard let version = filter.supportedDecoderVersions.first(where: { $0.rawValue == decoder }) else {
        fail("decoder \(decoder) not supported; supported: \(filter.supportedDecoderVersions.map(\.rawValue))")
    }
    filter.decoderVersion = version
}
let defaults = (luminance: filter.luminanceNoiseReductionAmount, color: filter.colorNoiseReductionAmount,
                sharpness: filter.sharpnessAmount)
filter.boostAmount = boost
if boost == 0 { filter.boostShadowAmount = 0 }
filter.exposure = 0
filter.extendedDynamicRangeAmount = 1
filter.isGamutMappingEnabled = boost != 0
filter.isDraftModeEnabled = false
filter.scaleFactor = scale
if filter.isContrastSupported { filter.contrastAmount = 0 }
if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
if !appleNR {
    if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
    if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
    if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
}
if let luma, filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = luma }
guard let image = filter.outputImage else { fail("no output for \(input.path)") }

let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
// Decoder 9 (macOS 27.0.1) renders correct colour only when the context's working
// space is linear sRGB: with a Display P3 or Rec.2020 working space its red channel
// collapses to zero (measured on Sony ARW and Ricoh DNG). Decoder 8 gives the same
// pixels in every working space. The extended space keeps P3 colours as signed
// components, and the TIFF is still written in extended linear Display P3.
let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let context = CIContext(options: [.workingColorSpace: working, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
do {
    try context.writeTIFFRepresentation(of: image, to: output, format: .RGBAf, colorSpace: space)
} catch {
    fail("write failed: \(error)")
}
let properties = filter.properties
let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
let facts: [String: Any] = [
    "input": input.lastPathComponent, "width": Int(image.extent.width), "height": Int(image.extent.height),
    "boost": boost, "baselineExposure": filter.baselineExposure, "appleNR": appleNR,
    "defaultLuminanceNR": defaults.luminance, "defaultColorNR": defaults.color, "defaultSharpness": defaults.sharpness,
    "iso": (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first ?? 0,
    "exposureTime": exif?[kCGImagePropertyExifExposureTime as String] ?? 0,
    "decoderVersion": filter.decoderVersion.rawValue,
]
let json = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)
