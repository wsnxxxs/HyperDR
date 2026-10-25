import Foundation

/// Where the HDR gain comes from (p7-adjustments §2.3). One choice instead of a
/// separate AI mode: the source decides where gain comes from, strength and range
/// decide how it is used. Option ids are also the `hdr.source.<id>` localization keys.
public enum HDRSource: String, Codable, CaseIterable, Sendable {
    /// Analytic expansion computed on the edited SDR base (`sdr` input).
    case expand
    /// Model inference on the original photo (`sdr` input).
    case ai
    /// Separated real highlights (`rawEDR` input, always on).
    case captured
    /// Real highlights plus expansion, taking the larger gain per pixel.
    case capturedExpand
    /// Real highlights plus AI, taking the larger gain per pixel.
    case capturedAI
    /// The photo already has HDR; `hdr` and `dual` inputs. Read-only, not a control.
    case builtIn

    public var domains: Set<InputDomain> {
        switch self {
        case .expand, .ai: return [.sdr]
        case .captured, .capturedExpand, .capturedAI: return [.rawEDR]
        case .builtIn: return [.hdr, .dual]
        }
    }

    public static func options(in domain: InputDomain) -> [HDRSource] {
        allCases.filter { $0.domains.contains(domain) }
    }

    public static func defaultSource(for domain: InputDomain) -> HDRSource {
        switch domain {
        case .sdr: return .expand
        case .rawEDR: return .captured
        case .hdr, .dual: return .builtIn
        }
    }

    /// Uses the analytic expansion (coverage applies).
    public var expands: Bool { self == .expand || self == .capturedExpand }
    /// Uses the AI model (model choice applies).
    public var usesModel: Bool { self == .ai || self == .capturedAI }
}

/// A film stock's kind. Negatives are printed on paper (motion-picture negatives
/// on print film); slides are viewed directly. Ids are `look.film.family.<id>` keys.
public enum FilmFamily: String, CaseIterable, Sendable {
    case negative, slide, cinema
}

/// The adjustment declarations. This table is the single source for the inspector,
/// undo names, localization keys and the GPU nodes (product-vision principle 4,
/// p7-adjustments §2.2–§2.7). 34 parameters: 6 RAW-only, 2 independent physical effects.
public enum Adjustments {
    /// Ceiling for HDR HyperDR generates itself: the analytic expansion on an `sdr`
    /// base and `rawEDR` (C1). Sources that already have HDR (`hdr`, `dual`) keep
    /// their own headroom when the range is automatic, up to the declared four stops;
    /// resolving that belongs to Render.
    public static let generatedRangeCeiling = 3.0
    /// C1: automatic expansion start for the analytic expansion, in the declared
    /// percent unit. AI keeps the model's own start.
    public static let automaticExpansionStart = 25.0

    /// Physical effects share the adjustment group but are independent of colour looks.
    public static let effectIDs = ["effect.grain", "effect.halation"]

    public static let all: [ParameterDeclaration] = hdr + light + color + look + detail

    public static let byID: [String: ParameterDeclaration] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    public static func declaration(_ id: String) -> ParameterDeclaration? { byID[id] }

    public static func parameters(in group: ParameterGroup) -> [ParameterDeclaration] {
        all.filter { $0.group == group }
    }

    /// Applies `domains` only; the inspector also evaluates `visibleWhen` through
    /// `visible(in:)`.
    public static func visible(in domain: InputDomain) -> [ParameterDeclaration] {
        all.filter { $0.allows(domain) }
    }

    public static func visible(in recipe: Recipe) -> [ParameterDeclaration] {
        all.filter { isVisible($0, in: recipe) }
    }

    public static func isVisible(_ declaration: ParameterDeclaration, in recipe: Recipe) -> Bool {
        declaration.isVisible(in: recipe.inputDomain, value: recipe.conditionValue)
    }

    // MARK: - HDR

    private static let hdr: [ParameterDeclaration] = [
        ParameterDeclaration(id: "hdr.enabled", group: .hdr, kind: .bool,
            default: .constant(.bool(true)), scope: .hdrOnly),
        ParameterDeclaration(id: "hdr.source", group: .hdr, kind: .choice,
            default: .byDomain(InputDomain.allCases.map {
                DomainDefault($0, .string(HDRSource.defaultSource(for: $0).rawValue))
            }),
            options: HDRSource.allCases.map { ParameterOption($0.rawValue, of: "hdr.source", domains: $0.domains) },
            visibleWhen: .isOn("hdr.enabled"), scope: .hdrOnly, cost: .inference),
        ParameterDeclaration(id: "hdr.model", group: .hdr, kind: .reference,
            default: .constant(.string("research-cnn-v1")),
            visibleWhen: .all([.isOn("hdr.enabled"), .isOneOf("hdr.source", ["ai", "capturedAI"])]),
            capability: "HyperDR.aiModels >= 2", scope: .hdrOnly, cost: .inference),
        ParameterDeclaration(id: "hdr.strength", group: .hdr, kind: .float, range: 0...200, step: 1,
            default: .constant(.number(100)), format: .percent, scale: .hundredth, origin: .zero,
            visibleWhen: .isOn("hdr.enabled"), scope: .hdrOnly, mask: "gain"),
        ParameterDeclaration(id: "hdr.range", group: .hdr, kind: .floatOrAuto, range: 0.5...4, step: 0.1,
            default: .auto, format: .stops, scale: .direct,
            visibleWhen: .isOn("hdr.enabled"), scope: .hdrOnly, mask: "gainFull"),
        ParameterDeclaration(id: "hdr.expansionStart", group: .hdr, kind: .floatOrAuto, range: 18...75, step: 1,
            default: .auto, format: .percent, scale: .hundredth,
            visibleWhen: .all([.isOn("hdr.enabled"),
                               .isOneOf("hdr.source", ["expand", "ai", "capturedExpand", "capturedAI"])]),
            scope: .hdrOnly, mask: "participation"),
        ParameterDeclaration(id: "hdr.coverage", group: .hdr, kind: .float, range: 0...100, step: 1,
            default: .constant(.number(60)), format: .percent, scale: .hundredth, origin: .zero,
            visibleWhen: .all([.isOn("hdr.enabled"),
                               .isOneOf("hdr.source", ["expand", "capturedExpand"])]),
            scope: .hdrOnly, mask: "coverage"),
        // The one SDR-only control: it changes the base and compensates the gain (H2).
        ParameterDeclaration(id: "hdr.sdrRolloff", group: .hdr, kind: .float, range: 0...100, step: 1,
            default: .constant(.number(0)), format: .percent, scale: .hundredth, origin: .zero,
            domains: [.rawEDR, .hdr], visibleWhen: .isOn("hdr.enabled"), scope: .sdrOnly),
    ]

    // MARK: - Light

    private static let light: [ParameterDeclaration] = [
        ParameterDeclaration(id: "tone.exposure", group: .light, kind: .float, range: -4...4, step: 0.01,
            default: .constant(.number(0)), format: .ev, scale: .direct, origin: .zero),
        ParameterDeclaration(id: "tone.contrast", group: .light, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .contrast, origin: .zero),
        ParameterDeclaration(id: "tone.highlights", group: .light, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .hundredth, origin: .zero, mask: "highlights"),
        ParameterDeclaration(id: "tone.shadows", group: .light, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .hundredth, origin: .zero, mask: "shadows"),
        ParameterDeclaration(id: "tone.whites", group: .light, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .hundredth, origin: .zero),
        ParameterDeclaration(id: "tone.blacks", group: .light, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .hundredth, origin: .zero, mask: "blacks"),
        ParameterDeclaration(id: "tone.curve", group: .light, kind: .curve,
            default: .constant(ToneCurve().parameterValue)),
    ]

    // MARK: - Color

    private static let lookSpaces = ["srgb", "p3", "rec709", "hlg", "pq", "slog3-sgamut3cine", "slog3-sgamut3", "vlog-vgamut", "flog2-fgamut", "logc3-awg3", "logc4-awg4", "clog3-cinemagamut"]
    // Append-only, matching Render's LUTSpace raw values. Log input is scene data.
    private static let logLookSpaces: Set<String> = ["slog3-sgamut3cine", "slog3-sgamut3", "vlog-vgamut", "flog2-fgamut", "logc3-awg3", "logc4-awg4", "clog3-cinemagamut"]

    private static let color: [ParameterDeclaration] = [
        // RAW white balance is a development parameter, not a matrix (p7-adjustments §2.5).
        // 1000…50000 K (user, 2026-10-25): underwater and deep-shade light need
        // both ends; the controls spread it in mired (`TrackSpacing.reciprocal`).
        ParameterDeclaration(id: "develop.temperature", group: .color, kind: .float, range: 1000...50000, step: 50,
            default: .fromSource, format: .kelvin, scale: .direct, domains: [.rawEDR], cost: .redevelop),
        ParameterDeclaration(id: "develop.tint", group: .color, kind: .float, range: -200...200, step: 1,
            default: .fromSource, format: .signed, scale: .direct, origin: .zero, domains: [.rawEDR], cost: .redevelop),
        ParameterDeclaration(id: "color.warmth", group: .color, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .hundredth, origin: .zero, domains: [.sdr, .hdr, .dual]),
        ParameterDeclaration(id: "color.tint", group: .color, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .hundredth, origin: .zero, domains: [.sdr, .hdr, .dual]),
        ParameterDeclaration(id: "color.vibrance", group: .color, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .hundredth, origin: .zero),
        ParameterDeclaration(id: "color.saturation", group: .color, kind: .float, range: -100...100, step: 1,
            default: .constant(.number(0)), format: .signed, scale: .hundredth, origin: .zero),
        // Zero bypasses the effect. One is the stock's own 35 mm model when a film
        // is selected, or the neutral 35 mm reference model without a film.
        ParameterDeclaration(id: "effect.grain", group: .color, kind: .float, range: 0...200, step: 1,
            default: .constant(.number(0)), format: .percent, scale: .hundredth, origin: .zero),
        ParameterDeclaration(id: "effect.halation", group: .color, kind: .float, range: 0...200, step: 1,
            default: .constant(.number(0)), format: .percent, scale: .hundredth, origin: .zero),
    ]

    // MARK: - Look

    private static let look: [ParameterDeclaration] = [
        ParameterDeclaration(id: "look.lut", group: .look, kind: .reference,
            default: .constant(.none)),
        ParameterDeclaration(id: "look.enabled", group: .look, kind: .bool,
            default: .constant(.bool(true)), visibleWhen: .isSet("look.lut")),
        ParameterDeclaration(id: "look.strength", group: .look, kind: .float, range: 0...100, step: 1,
            default: .constant(.number(100)), format: .percent, scale: .hundredth, origin: .zero,
            visibleWhen: .isSet("look.lut")),
        ParameterDeclaration(id: "look.input", group: .look, kind: .choice,
            default: .constant(.string("srgb")),
            options: lookSpaces.map {
                ParameterOption($0, of: "look.input",
                                domains: logLookSpaces.contains($0) ? [.rawEDR] : Set(InputDomain.allCases))
            },
            visibleWhen: .isSet("look.lut")),
        ParameterDeclaration(id: "look.output", group: .look, kind: .choice,
            default: .constant(.string("srgb")),
            options: lookSpaces.map { ParameterOption($0, of: "look.output") },
            visibleWhen: .isSet("look.lut")),
        // Film emulation from spektrafilm's measured stocks, evaluated by Render.
        // Append-only option ids; Render bundles one resource per stock.
        ParameterDeclaration(id: "look.film", group: .look, kind: .choice,
            default: .constant(.string("none")),
            options: filmStocks.map { ParameterOption($0, of: "look.film") }),
        // Auto meters the original photo centre-weighted to 18.4 % grey, as spektrafilm's camera.
        ParameterDeclaration(id: "look.filmExposure", group: .look, kind: .floatOrAuto, range: -3...3, step: 0.1,
            default: .auto, format: .ev, scale: .direct,
            visibleWhen: .isOneOf("look.film", Array(filmStocks.dropFirst()))),
        ParameterDeclaration(id: "look.filmStrength", group: .look, kind: .float, range: 0...100, step: 1,
            default: .constant(.number(100)), format: .percent, scale: .hundredth, origin: .zero,
            visibleWhen: .isOneOf("look.film", Array(filmStocks.dropFirst()))),
        // Off: the film without its antihalation layer, as CineStill does to Vision3.
        ParameterDeclaration(id: "look.filmAntihalation", group: .look, kind: .bool,
            default: .constant(.bool(true)),
            visibleWhen: .isOneOf("look.film", Array(filmStocks.dropFirst()))),
    ]

    /// `none` first, then the stocks Render bundles, in menu order: colour negatives,
    /// slides, motion-picture negatives. Ids are stable; the order is only the menu's.
    /// A literal list: scripts/check_apple_i18n.py reads the option keys from it.
    public static let filmStocks = ["none", "portra400", "gold200", "velvia100", "kodachrome64", "vision3-500t"]

    /// The stocks of each kind, for menu sections; together, `filmStocks` after `none`.
    public static let filmFamilies: [(family: FilmFamily, stocks: [String])] = [
        (.negative, ["portra400", "gold200"]),
        (.slide, ["velvia100", "kodachrome64"]),
        (.cinema, ["vision3-500t"]),
    ]

    public static func filmFamily(_ stock: String) -> FilmFamily? {
        filmFamilies.first { $0.stocks.contains(stock) }?.family
    }

    // MARK: - Detail (RAW only)

    private static let detail: [ParameterDeclaration] = [
        ParameterDeclaration(id: "develop.luminanceNR", group: .detail, kind: .float, range: 0...100, step: 1,
            default: .fromSource, format: .percent, scale: .hundredth, domains: [.rawEDR],
            capability: "CIRAWFilter.isLuminanceNoiseReductionSupported", cost: .redevelop),
        ParameterDeclaration(id: "develop.colorNR", group: .detail, kind: .float, range: 0...100, step: 1,
            default: .fromSource, format: .percent, scale: .hundredth, domains: [.rawEDR],
            capability: "CIRAWFilter.isColorNoiseReductionSupported", cost: .redevelop),
        ParameterDeclaration(id: "develop.sharpness", group: .detail, kind: .float, range: 0...100, step: 1,
            default: .fromSource, format: .percent, scale: .hundredth, domains: [.rawEDR],
            capability: "CIRAWFilter.isSharpnessSupported", cost: .redevelop),
        ParameterDeclaration(id: "develop.lensCorrection", group: .detail, kind: .bool,
            default: .constant(.bool(true)), domains: [.rawEDR],
            capability: "CIRAWFilter.isLensCorrectionSupported", cost: .redevelop),
    ]
}
