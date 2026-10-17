import Foundation
import HyperDREngine

/// The presentation frame placed around an export: five layouts, five paper
/// tones, and what the caption says. Every proportion is a fraction of the
/// photograph's short edge, so a frame looks the same at any export size, and
/// the engine's `hyperdr_frame_layout` turns it into the exact pixels that the
/// preview draws and the export writes.
///
/// Everything here is SDR. The engine writes the frame identically into both
/// renditions, so the frame shows at reference white on an HDR display while
/// the photograph keeps its headroom: paper white beside the print is what
/// makes its highlights read as light.
enum FrameStyle: String, CaseIterable, Identifiable, Codable {
    case gallery, label, story, instant, hairline

    var id: Self { self }

    /// Mats, caption band, canvas proportion and print shadow.
    var geometry: FrameGeometry {
        switch self {
        case .gallery:
            FrameGeometry(top: 0.06, right: 0.06, bottom: 0.06, left: 0.06, caption: 0.13,
                          shadow: FrameShadow(opacity: 0.10, blur: 0.012, offset: 0.004))
        case .label:
            FrameGeometry(top: 0.10, right: 0.10, bottom: 0.07, left: 0.10, caption: 0.12,
                          shadow: FrameShadow(opacity: 0.08, blur: 0.010, offset: 0.003))
        case .story:
            FrameGeometry(top: 0.055, right: 0.055, bottom: 0.04, left: 0.055, caption: 0.16,
                          aspect: FrameAspect(width: 9, height: 16, topShare: 0.42))
        case .instant:
            FrameGeometry(top: 0.045, right: 0.045, bottom: 0.03, left: 0.045, caption: 0.19)
        case .hairline:
            FrameGeometry(top: 0.02, right: 0.02, bottom: 0.02, left: 0.02, caption: 0)
        }
    }

    /// Whether this layout has room for a caption at all.
    var hasCaption: Bool { geometry.caption > 0 }
}

/// Fractions of the photograph's short edge.
struct FrameGeometry: Equatable {
    var top, right, bottom, left: Double
    var caption: Double
    var aspect: FrameAspect? = nil
    var shadow: FrameShadow? = nil
}

/// A fixed canvas proportion; `topShare` of the added height goes above the photo.
struct FrameAspect: Equatable {
    var width, height: Int
    var topShare: Double
}

/// The print's shadow on the mat: darkening at its core, Gaussian sigma and
/// downward offset, the last two as fractions of the short edge.
struct FrameShadow: Equatable {
    var opacity, blur, offset: Double
}

/// A colour as a #RRGGBB value in Display P3 with the sRGB transfer: the
/// engine reads the background exactly so, and the views draw it so.
struct FrameColor: Equatable {
    let red, green, blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }
}

enum FrameTone: String, CaseIterable, Identifiable, Codable {
    case paper, snow, mist, graphite, ink

    var id: Self { self }

    var background: FrameColor {
        switch self {
        case .paper: FrameColor(hex: 0xF5F3EE)
        case .snow: FrameColor(hex: 0xFFFFFF)
        case .mist: FrameColor(hex: 0xE6E5E1)
        case .graphite: FrameColor(hex: 0x2B2B2E)
        case .ink: FrameColor(hex: 0x0D0D0F)
        }
    }

    /// Exposure line and signature.
    var primaryInk: FrameColor {
        switch self {
        case .paper, .snow, .mist: FrameColor(hex: 0x1D1D1F)
        case .graphite: FrameColor(hex: 0xF2F2F0)
        case .ink: FrameColor(hex: 0xEDEDED)
        }
    }

    /// Camera, lens and date.
    var secondaryInk: FrameColor {
        switch self {
        case .paper: FrameColor(hex: 0x6F6C66)
        case .snow: FrameColor(hex: 0x6E6E73)
        case .mist: FrameColor(hex: 0x5F5D58)
        case .graphite: FrameColor(hex: 0xA4A4A8)
        case .ink: FrameColor(hex: 0x8E8E93)
        }
    }
}

/// What the user chose. Kept across launches; applied by export once enabled.
struct FrameSettings: Equatable, Codable {
    var isEnabled = false
    var style: FrameStyle = .gallery
    var tone: FrameTone = .paper
    var showsShadow = true
    var showsExposure = true
    var showsCamera = true
    var showsDate = false
    var signature = ""

    /// The hyperdr.frame/v1 document. Without caption text the band is
    /// dropped, so a gallery mat with nothing to say is even on all sides.
    func engineFrame(hasCaption: Bool, overlay: URL? = nil) -> [String: JSONValue] {
        let geometry = style.geometry
        var frame: [String: JSONValue] = [
            "schema": .string("hyperdr.frame/v1"),
            "background": .string(tone.background.hex),
            "margins": .object(["top": .number(geometry.top), "right": .number(geometry.right),
                                "bottom": .number(geometry.bottom), "left": .number(geometry.left)]),
            "caption": .number(hasCaption ? geometry.caption : 0),
            "reference": .string("short"),
        ]
        if let aspect = geometry.aspect {
            frame["aspect"] = .object(["width": .number(Double(aspect.width)),
                                       "height": .number(Double(aspect.height)),
                                       "topShare": .number(aspect.topShare)])
        }
        if showsShadow, let shadow = geometry.shadow {
            frame["shadow"] = .object(["opacity": .number(shadow.opacity), "blur": .number(shadow.blur),
                                       "offset": .number(shadow.offset)])
        }
        if let overlay { frame["overlay"] = .string(overlay.path) }
        return frame
    }

    private static let defaultsKey = "FrameSettings"

    static func load(from defaults: UserDefaults = .standard) -> FrameSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(FrameSettings.self, from: data) else { return FrameSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

// MARK: - Caption

/// One line of a caption. Sizes and gaps are fractions of the short edge, so
/// the same caption draws in the preview and renders at export size.
struct FrameCaptionLine: Equatable, Identifiable {
    enum Ink { case primary, secondary }
    enum Face { case text, semibold, signature }

    let id: Int
    var text: String
    var ink: Ink
    var face: Face
    var size: Double
    var gap: Double = 0
    /// Letter spacing in em.
    var tracking: Double = 0
}

struct FrameCaption: Equatable {
    enum Placement: Equatable {
        /// Centred in the band; `abovePaperMargin` leaves the bottom mat clear.
        case middle(abovePaperMargin: Bool)
        /// This far below the photograph.
        case top(Double)
    }

    var leading: [FrameCaptionLine] = []
    var center: [FrameCaptionLine] = []
    var trailing: [FrameCaptionLine] = []
    var placement: Placement = .middle(abovePaperMargin: false)

    var isEmpty: Bool { leading.isEmpty && center.isEmpty && trailing.isEmpty }
}

extension FrameStyle {
    /// The caption this style sets for these settings and this photograph.
    func caption(_ settings: FrameSettings, facts: CaptureFacts) -> FrameCaption {
        var caption = FrameCaption()
        var next = 0
        func line(_ text: String?, _ ink: FrameCaptionLine.Ink, _ face: FrameCaptionLine.Face,
                  _ size: Double, gap: Double = 0, tracking: Double = 0) -> FrameCaptionLine? {
            guard let text, !text.isEmpty else { return nil }
            defer { next += 1 }
            return FrameCaptionLine(id: next, text: text, ink: ink, face: face, size: size,
                                    gap: gap, tracking: tracking)
        }
        let signature = settings.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        let exposure = settings.showsExposure ? facts.exposureLine : nil
        let date = settings.showsDate ? facts.dateLine : nil

        switch self {
        case .gallery, .story:
            let large = self == .story
            caption.center = [
                line(exposure, .primary, .text, large ? 0.03 : 0.024),
                line(settings.showsCamera ? facts.cameraLine : nil, .secondary, .text, large ? 0.02 : 0.0175, gap: 0.012),
                line(date, .secondary, .text, 0.016, gap: 0.008),
                line(signature, .primary, .signature, large ? 0.036 : 0.03, gap: large ? 0.05 : 0.022),
            ].compactMap { $0 }
            caption.placement = large ? .top(0.045) : .middle(abovePaperMargin: false)
        case .label:
            caption.leading = [
                line(settings.showsCamera ? facts.cameraLabel : nil, .primary, .semibold, 0.019, tracking: 0.14),
                line(settings.showsCamera ? facts.lensName : nil, .secondary, .text, 0.0165, gap: 0.008),
                line(exposure, .secondary, .text, 0.0165, gap: 0.006),
            ].compactMap { $0 }
            caption.trailing = [
                line(signature, .primary, .signature, 0.028),
                line(date, .secondary, .text, 0.0155, gap: 0.008),
            ].compactMap { $0 }
            caption.placement = .top(0.035)
        case .instant:
            let name = signature.isEmpty && settings.showsCamera ? facts.cameraName : nil
            caption.leading = [
                line(signature, .primary, .signature, 0.045),
                line(name, .primary, .semibold, 0.022, tracking: 0.08),
            ].compactMap { $0 }
            caption.trailing = [
                line(date, .secondary, .text, 0.016),
                line(exposure, .secondary, .text, 0.016, gap: 0.006),
            ].compactMap { $0 }
            caption.placement = .middle(abovePaperMargin: true)
        case .hairline:
            break
        }
        // The first line of a column sits on the placement, not below a gap.
        for keyPath in [\FrameCaption.leading, \.center, \.trailing] where !caption[keyPath: keyPath].isEmpty {
            caption[keyPath: keyPath][0].gap = 0
        }
        return caption
    }
}
