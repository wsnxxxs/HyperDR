import Foundation
import ImageIO

/// The capture facts a frame caption shows, read from the photograph's own
/// Exif. Formatting is photographic, not locale dependent: a photographer
/// reads "f/2.8" and "1/250 s" in any language.
///
/// Plain values and pure functions, off the main actor: the services read
/// the Exif in the background.
nonisolated struct CaptureFacts: Equatable, Sendable {
    var make: String?
    var model: String?
    var lens: String?
    var focalLength: Double?
    var fNumber: Double?
    var exposureTime: Double?
    var iso: Int?
    /// Exif DateTimeOriginal, "YYYY:MM:DD HH:MM:SS".
    var dateTimeOriginal: String?

    /// Reads the first image's Exif with ImageIO, which also covers camera RAW.
    /// The caller holds any security scope the URL needs.
    static func read(_ url: URL) -> CaptureFacts {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return CaptureFacts() }
        return CaptureFacts(properties: properties)
    }

    init(make: String? = nil, model: String? = nil, lens: String? = nil, focalLength: Double? = nil,
         fNumber: Double? = nil, exposureTime: Double? = nil, iso: Int? = nil, dateTimeOriginal: String? = nil) {
        self.make = Self.recorded(make)
        self.model = Self.recorded(model)
        self.lens = Self.recorded(lens)
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.iso = iso
        self.dateTimeOriginal = Self.recorded(dateTimeOriginal)
    }

    /// The text, trimmed, or nil when nothing real was recorded: empty, a
    /// placeholder of dashes, or "unknown", "n/a" or "none" in any case.
    /// Sony writes LensModel "----" when no lens reported itself, which a
    /// caption would otherwise print.
    static func recorded(_ value: String?) -> String? {
        guard let string = value?.trimmingCharacters(in: Self.padding),
              string.contains(where: { $0 != "-" && !$0.isWhitespace }),
              !Self.placeholders.contains(string.lowercased()) else { return nil }
        return string
    }

    private static let placeholders: Set<String> = ["unknown", "n/a", "none"]

    /// Whitespace, and the NULs that pad fixed-length Exif strings.
    private static let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))

    init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let text = { (value: Any?) -> String? in Self.recorded(value as? String) }
        let number = { (value: Any?) -> Double? in
            guard let value = (value as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return value
        }
        make = text(tiff[kCGImagePropertyTIFFMake])
        model = text(tiff[kCGImagePropertyTIFFModel])
        lens = text(exif[kCGImagePropertyExifLensModel])
        focalLength = number(exif[kCGImagePropertyExifFocalLength])
        fNumber = number(exif[kCGImagePropertyExifFNumber])
        exposureTime = number(exif[kCGImagePropertyExifExposureTime])
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first.map(\.intValue)
            .flatMap { $0 > 0 ? $0 : nil }
        dateTimeOriginal = text(exif[kCGImagePropertyExifDateTimeOriginal])
    }

    // MARK: Caption text

    /// "35 mm  ·  f/8  ·  1/250 s  ·  ISO 100", leaving out what was not recorded.
    var exposureLine: String? {
        let parts = [focalLength.map { "\(Self.decimal($0)) mm" },
                     fNumber.map { "f/\(Self.decimal($0))" },
                     exposureTime.map(Self.shutter),
                     iso.map { "ISO \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: Self.separator)
    }

    /// "Sony α7R V", "Ricoh GR IIIx", "iPhone 17 Pro".
    var cameraName: String? { camera(capitalBrand: false) }

    /// "SONY α7R V": the brand in capitals, the model as its maker writes it
    /// (uppercasing all of it would turn α into a Greek capital that reads as A).
    var cameraLabel: String? { camera(capitalBrand: true) }

    private func camera(capitalBrand: Bool) -> String? {
        let brand = make.map(Self.brand).map { capitalBrand && $0 != "Apple" ? $0.uppercased() : $0 }
        guard var name = model else { return brand }
        if let make, name.lowercased().hasPrefix(make.lowercased()) {
            name = String(name.dropFirst(make.count)).trimmingCharacters(in: .whitespaces)
        } else if let brand, name.lowercased().hasPrefix(brand.lowercased()) {
            name = String(name.dropFirst(brand.count)).trimmingCharacters(in: .whitespaces)
        }
        name = Self.sonyAlpha(name) ?? name
        guard let brand, brand != "Apple", !name.isEmpty else { return name.isEmpty ? brand : name }
        return "\(brand) \(name)"
    }

    /// The lens with typographic ranges: "FE 24–70mm F2.8 GM II".
    var lensName: String? {
        lens?.replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1–$2", options: .regularExpression)
    }

    /// "Sony α7R V  ·  FE 24–70mm F2.8 GM II".
    var cameraLine: String? {
        let parts = [cameraName, lensName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: Self.separator)
    }

    /// "2026.09.21".
    var dateLine: String? {
        guard let date = dateTimeOriginal?.prefix(10), date.count == 10 else { return nil }
        return date.replacingOccurrences(of: ":", with: ".")
    }

    static let separator = "  ·  "

    /// 8 → "8", 2.8 → "2.8", 18.3 → "18.3".
    static func decimal(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0
            ? String(Int(tenths / 10)) : String(format: "%.1f", tenths / 10)
    }

    /// 1/250 s, 1/4 s, 0.3 s, 0.4 s, 0.6 s, 1.3 s, 30 s. From 0.3 s up, a
    /// fraction would be wrong (0.4 s is not 1/3 s nor 1/2 s), so cameras
    /// show tenths of a second; shorter times are the 1/n camera stops.
    static func shutter(_ seconds: Double) -> String {
        if seconds >= 0.3 { return "\(decimal(seconds)) s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    static func brand(_ make: String) -> String {
        let key = make.uppercased()
        let known: [(prefix: String, name: String)] = [
            ("NIKON", "Nikon"), ("CANON", "Canon"), ("SONY", "Sony"), ("FUJIFILM", "Fujifilm"),
            ("RICOH", "Ricoh"), ("PENTAX", "Pentax"), ("OLYMPUS", "Olympus"), ("OM DIGITAL", "OM System"),
            ("PANASONIC", "Panasonic"), ("LEICA", "Leica"), ("HASSELBLAD", "Hasselblad"),
            ("SIGMA", "Sigma"), ("APPLE", "Apple"), ("DJI", "DJI"), ("GOOGLE", "Google")]
        return known.first { key.hasPrefix($0.prefix) }?.name ?? make
    }

    /// Sony writes the body code: ILCE-7RM5 is the α7R V, ILCE-1M2 the α1 II.
    static func sonyAlpha(_ model: String) -> String? {
        guard model.uppercased().hasPrefix("ILCE-") else { return nil }
        let code = model.dropFirst(5)
        let numerals = ["2": "II", "3": "III", "4": "IV", "5": "V", "6": "VI", "7": "VII", "8": "VIII", "9": "IX"]
        if let marker = code.lastIndex(of: "M"), code.index(after: marker) < code.endIndex,
           let numeral = numerals[String(code[code.index(after: marker)...])], marker > code.startIndex {
            return "α\(code[..<marker]) \(numeral)"
        }
        return "α\(code)"
    }
}
