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
                          aspect: FrameAspect(width: 9, height: 16, topShare: 0.42),
                          variants: [
                              // A panorama: a landscape card, margins and caption by the long edge.
                              FrameVariant(name: "wide", minRatio: 2.5, margins: FrameMargins(all: 0.02), caption: 0.06,
                                           referencesLongEdge: true),
                              // A very tall photo: the 9:16 canvas gives way to the plain mat.
                              FrameVariant(name: "tall", maxRatio: 0.125),
                          ])
        case .instant:
            FrameGeometry(top: 0.045, right: 0.045, bottom: 0.03, left: 0.045, caption: 0.19,
                          variants: [
                              // A panorama: the 2.5:1 card (these numbers are the plain ones
                              // divided by 2.5) grown by the long edge, so margins and text
                              // keep their share of the width instead of shrinking to a strip.
                              FrameVariant(name: "wide", minRatio: 2.5,
                                           margins: FrameMargins(top: 0.018, right: 0.018, bottom: 0.012, left: 0.018),
                                           caption: 0.076, referencesLongEdge: true),
                          ])
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
    var variants: [FrameVariant] = []

    /// What the engine lays out for the variant it picked: the margins, band
    /// and reference the variant overrides, and no forced canvas proportion.
    func applying(_ name: String?) -> FrameGeometry {
        guard let name, let variant = variants.first(where: { $0.name == name }) else { return self }
        var result = self
        if let margins = variant.margins {
            result.top = margins.top; result.right = margins.right; result.bottom = margins.bottom; result.left = margins.left
        }
        if let caption = variant.caption { result.caption = caption }
        result.aspect = nil
        result.variants = []
        return result
    }
}

/// An alternative layout the engine picks by the photograph's width / height:
/// `minRatio` for photographs wider than it, `maxRatio` for narrower. Keys it
/// does not override come from the style. See the engine's `variants`.
struct FrameVariant: Equatable {
    var name: String
    var minRatio: Double? = nil
    var maxRatio: Double? = nil
    var margins: FrameMargins? = nil
    var caption: Double? = nil
    var referencesLongEdge = false
}

/// The mat on each side, as a fraction of the reference edge.
struct FrameMargins: Equatable {
    var top, right, bottom, left: Double

    init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }

    /// The same mat on all four sides.
    init(all margin: Double) { self.init(top: margin, right: margin, bottom: margin, left: margin) }
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
        if !geometry.variants.isEmpty {
            frame["variants"] = .object(Dictionary(uniqueKeysWithValues: geometry.variants.map { variant in
                // A variant drops the style's forced canvas proportion, if it has one.
                var entry: [String: JSONValue] = geometry.aspect == nil ? [:] : ["aspect": .null]
                if let minRatio = variant.minRatio { entry["minRatio"] = .number(minRatio) }
                if let maxRatio = variant.maxRatio { entry["maxRatio"] = .number(maxRatio) }
                if let margins = variant.margins {
                    entry["margins"] = .object(["top": .number(margins.top), "right": .number(margins.right),
                                                "bottom": .number(margins.bottom), "left": .number(margins.left)])
                }
                // Without a caption the band goes in every layout, not just the default.
                if let caption = variant.caption { entry["caption"] = .number(hasCaption ? caption : 0) }
                else if !hasCaption { entry["caption"] = .number(0) }
                if variant.referencesLongEdge { entry["reference"] = .string("long") }
                return (variant.name, .object(entry))
            }))
        }
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

extension FrameCaption {
    /// The height the text takes below the photograph, in units of the
    /// reference edge, with lines `lineHeight` times their size tall.
    func contentHeight(lineHeight: Double = 1.2) -> Double {
        var offset = 0.0
        if case .top(let fraction) = placement { offset = fraction }
        let columns = [leading, center, trailing].map { column in
            column.reduce(0) { $0 + $1.gap + $1.size * lineHeight }
        }
        return offset + (columns.max() ?? 0)
    }
}

extension FrameStyle {
    /// The size of this style's smallest body text, per reference edge, when
    /// the engine picked `variant`: what the preview keeps readable.
    func bodySize(variant: String?) -> Double? {
        self == .story && variant == "wide" ? 0.010 : nil
    }

    /// The caption this style sets for these settings and this photograph.
    /// `variant` is the layout the engine picked (`FramePixelLayout.variant`);
    /// `bandHeight` the caption band in units of the reference edge. When the
    /// text at full spacing is taller than the band, story sets it tighter.
    func caption(_ settings: FrameSettings, facts: CaptureFacts, variant: String? = nil,
                 bandHeight: Double? = nil) -> FrameCaption {
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
        case .story where variant == "wide":
            // Two columns in a short band, centred in it above the bottom mat.
            caption.leading = [
                line(exposure, .primary, .text, 0.014),
                line(settings.showsCamera ? facts.cameraLine : nil, .secondary, .text, 0.010, gap: 0.004),
            ].compactMap { $0 }
            caption.trailing = [
                line(signature, .primary, .signature, 0.016),
                line(date, .secondary, .text, 0.008, gap: 0.003),
            ].compactMap { $0 }
            caption.placement = .middle(abovePaperMargin: true)
        case .gallery, .story:
            let large = self == .story
            func column(compact: Bool) -> [FrameCaptionLine] {
                next = 0
                return [
                    line(exposure, .primary, .text, large ? 0.03 : 0.024),
                    line(settings.showsCamera ? facts.cameraLine : nil, .secondary, .text, large ? 0.02 : 0.0175, gap: 0.012),
                    line(date, .secondary, .text, 0.016, gap: 0.008),
                    line(signature, .primary, .signature, large ? (compact ? 0.030 : 0.036) : 0.03,
                         gap: large ? (compact ? 0.030 : 0.05) : 0.022),
                ].compactMap { $0 }
            }
            caption.center = column(compact: false)
            caption.placement = large ? .top(0.045) : .middle(abovePaperMargin: false)
            if large, let bandHeight, caption.contentHeight() > bandHeight {
                caption.center = column(compact: true)
                caption.placement = .top(0.035)
            }
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
        case .instant where variant == "wide":
            // The 2.5:1 caption (every size divided by 2.5), by the long edge.
            let name = signature.isEmpty && settings.showsCamera ? facts.cameraName : nil
            caption.leading = [
                line(signature, .primary, .signature, 0.018),
                line(name, .primary, .semibold, 0.0088, tracking: 0.08),
            ].compactMap { $0 }
            caption.trailing = [
                line(date, .secondary, .text, 0.0064),
                line(exposure, .secondary, .text, 0.0064, gap: 0.0024),
            ].compactMap { $0 }
            caption.placement = .middle(abovePaperMargin: true)
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
