import Foundation

/// The source's display-referred input domain, before any editing (gpu-pipeline §3).
public enum InputDomain: String, Codable, CaseIterable, Sendable {
    /// SDR photo: nothing above SDR white. HDR comes from expansion or AI.
    case sdr
    /// HDR photo whose pixels already carry real values above SDR white (HLG, PQ, HDR JPEG).
    case hdr
    /// Photo with an authored ISO or Apple gain map; the base and gain are both kept.
    case dual
    /// RAW developed through `CIRAWFilter`; highlights above SDR white are captured data.
    case rawEDR
}

/// Inspector groups in display order (p7-adjustments §2.1).
public enum ParameterGroup: String, Codable, CaseIterable, Sendable {
    case hdr, light, color, look, detail
    /// Reserved for local masks (p7-adjustments §2.9). No parameter declares it yet.
    case local

    public static let displayOrder: [ParameterGroup] = [.hdr, .light, .color, .look, .detail, .local]

    public var labelKey: String { "group.\(rawValue)" }
}

public enum ParameterKind: String, Codable, CaseIterable, Sendable {
    /// A continuous number with a static range.
    case float
    /// A continuous number that can also follow the automatic resolution.
    case floatOrAuto
    case bool
    /// One of the declaration's `options`.
    case choice
    /// A named resource: a LUT (`look.lut`) or a model (`hdr.model`).
    case reference
}

/// One recipe value: a small JSON tree, so a value this build does not understand
/// (an object from a newer build) still survives a round trip. Numbers are held as
/// `Double`, so integers above 2^53 lose precision; `.none` is a JSON null and also a
/// deliberate "no reference".
public enum ParameterValue: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case array([ParameterValue])
    case object([String: ParameterValue])
    case none

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [ParameterValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: ParameterValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension ParameterValue: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
            return
        }
        // JSON booleans decode as booleans; the decoder rejects them as numbers.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ParameterValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ParameterValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported recipe value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value):
            var keyed = encoder.container(keyedBy: Key.self)
            for (name, element) in value {
                try keyed.encode(element, forKey: Key(stringValue: name))
            }
        case .none: try container.encodeNil()
        }
    }
}

/// One entry of a default table that depends on the input domain (`hdr.source`).
public struct DomainDefault: Codable, Equatable, Sendable {
    public let domain: InputDomain
    public let value: ParameterValue
    public init(_ domain: InputDomain, _ value: ParameterValue) {
        self.domain = domain
        self.value = value
    }
}

/// Where a control starts and what its reset restores (p7-adjustments §2.2).
public enum ParameterDefault: Equatable, Sendable {
    /// A fixed value.
    case constant(ParameterValue)
    /// The file's or Apple's value: RAW white balance, Apple noise reduction and sharpness.
    case fromSource
    /// Resolved by the renderer from the source content: range, expansion start.
    case auto
    /// A fixed value that depends on the input domain.
    case byDomain([DomainDefault])
}

extension ParameterDefault: Codable {
    private enum CodingKeys: String, CodingKey { case constant, fromSource, auto, byDomain }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.constant) {
            // `decode` rather than `decodeIfPresent`: `.constant(.none)` is a JSON null.
            self = .constant(try container.decode(ParameterValue.self, forKey: .constant))
        } else if container.contains(.fromSource) {
            self = .fromSource
        } else if container.contains(.auto) {
            self = .auto
        } else if let table = try container.decodeIfPresent([DomainDefault].self, forKey: .byDomain) {
            self = .byDomain(table)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .constant, in: container, debugDescription: "Unknown parameter default")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .constant(let value): try container.encode(value, forKey: .constant)
        case .fromSource: try container.encode(true, forKey: .fromSource)
        case .auto: try container.encode(true, forKey: .auto)
        case .byDomain(let table): try container.encode(table, forKey: .byDomain)
        }
    }
}

/// How the readout is written. Non-numeric kinds carry no format. This is display
/// only; the value a node receives is decided by `ParameterScale`.
public enum ParameterFormat: String, Codable, CaseIterable, Sendable {
    /// Exposure in EV, `+0.30`.
    case ev
    /// Signed integer, `+8` / `−42`.
    case signed
    /// A level in percent; the engine receives the same value divided by 100.
    case percent
    /// Headroom in log2 stops, `2.4`.
    case stops
    /// Colour temperature in kelvin, `5500`.
    case kelvin
    case integer
}

/// Which end of the slider the fill grows from.
public enum ParameterOrigin: String, Codable, CaseIterable, Sendable {
    case zero, lower
}

/// How a declared value reaches the node. Kept apart from `ParameterFormat` so that a
/// readout unit never decides an engine unit: RAW `develop.tint` reads as a signed
/// number and is passed through, while `tone.shadows` reads the same way and is a
/// normalized level.
public enum ParameterScale: String, Codable, CaseIterable, Sendable {
    /// The node takes the declared unit: EV, stops, kelvin, a CIRAWFilter amount.
    case direct
    /// The node takes a normalized level: declared `60` becomes `0.6`.
    case hundredth
    /// The node takes a contrast multiplier: declared `v` becomes `1.6^(v/100)`.
    case contrast
}

/// Which rendition a parameter changes (p7-adjustments §1).
public enum ParameterScope: String, Codable, CaseIterable, Sendable {
    /// Both renditions move together.
    case whole
    /// Only the gain above SDR white; the SDR base stays pixel-identical (H1).
    case hdrOnly
    /// Only the SDR base; gain compensates so the HDR rendition stays (H2).
    case sdrOnly
}

/// What re-running this parameter costs.
public enum ParameterCost: String, Codable, CaseIterable, Sendable {
    /// Only the downstream nodes are recomputed.
    case instant
    /// RAW has to be developed again.
    case redevelop
    /// A model has to run.
    case inference
}

/// One selectable value of a `choice` declaration. `labelKey` is `<parameter>.<id>`,
/// e.g. `hdr.source.expand` (p7-adjustments §7).
public struct ParameterOption: Codable, Equatable, Sendable {
    public let id: String
    public let labelKey: String
    /// Domains in which this option is offered; the others are not shown at all.
    public let domains: Set<InputDomain>

    public init(_ id: String, of parameter: String,
                domains: Set<InputDomain> = Set(InputDomain.allCases)) {
        self.id = id
        self.labelKey = "\(parameter).\(id)"
        self.domains = domains
    }
}

/// `visibleWhen` from p7-adjustments §2.2, as a small evaluable expression instead of a
/// string, so the inspector can be generated from the table. Missing values read as false.
public indirect enum ParameterCondition: Equatable, Sendable {
    /// The referenced boolean parameter is on.
    case isOn(String)
    /// The referenced parameter has a value that is not `.none` (a chosen LUT).
    case isSet(String)
    /// The referenced choice parameter holds one of these option ids.
    case isOneOf(String, [String])
    case all([ParameterCondition])

    public func isSatisfied(_ value: (String) -> ParameterValue?) -> Bool {
        switch self {
        case .isOn(let id):
            return value(id) == .bool(true)
        case .isSet(let id):
            guard let value = value(id) else { return false }
            return value != .none
        case .isOneOf(let id, let allowed):
            guard let option = value(id)?.stringValue else { return false }
            return allowed.contains(option)
        case .all(let conditions):
            return conditions.allSatisfy { $0.isSatisfied(value) }
        }
    }
}

extension ParameterCondition: Codable {
    private enum CodingKeys: String, CodingKey { case on, set, oneOf, all }
    private enum ReferenceKeys: String, CodingKey { case id, values }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .on) {
            self = .isOn(id)
        } else if let id = try container.decodeIfPresent(String.self, forKey: .set) {
            self = .isSet(id)
        } else if let reference = try? container.nestedContainer(keyedBy: ReferenceKeys.self, forKey: .oneOf) {
            self = .isOneOf(try reference.decode(String.self, forKey: .id),
                            try reference.decode([String].self, forKey: .values))
        } else if let conditions = try container.decodeIfPresent([ParameterCondition].self, forKey: .all) {
            self = .all(conditions)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .on, in: container, debugDescription: "Unknown parameter condition")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .isOn(let id):
            try container.encode(id, forKey: .on)
        case .isSet(let id):
            try container.encode(id, forKey: .set)
        case .isOneOf(let id, let allowed):
            var reference = container.nestedContainer(keyedBy: ReferenceKeys.self, forKey: .oneOf)
            try reference.encode(id, forKey: .id)
            try reference.encode(allowed, forKey: .values)
        case .all(let conditions):
            try container.encode(conditions, forKey: .all)
        }
    }
}

/// Shared by render nodes and the controls that edit them. `id` is the stable recipe
/// key, also the source of the localization keys and the undo name (p7-adjustments §2.2).
public struct ParameterDeclaration: Codable, Equatable, Sendable {
    public let id: String
    public let group: ParameterGroup
    public let kind: ParameterKind
    /// Static range; `nil` for `bool`, `choice` and `reference`.
    public let range: ClosedRange<Double>?
    /// Keyboard and stepper increment; `nil` for non-numeric kinds.
    public let step: Double?
    public let `default`: ParameterDefault
    public let format: ParameterFormat?
    /// How the node receives the value; `.direct` for non-numeric kinds.
    public let scale: ParameterScale
    public let origin: ParameterOrigin
    public let domains: Set<InputDomain>
    /// Selectable values, in display order; empty unless `kind == .choice`.
    public let options: [ParameterOption]
    /// Extra visibility rule on top of `domains`.
    public let visibleWhen: ParameterCondition?
    /// Runtime capability check, e.g. `CIRAWFilter.isLuminanceNoiseReductionSupported`.
    /// Not evaluated here; the app resolves it against the source.
    public let capability: String?
    public let scope: ParameterScope
    /// Canvas overlay while the control is hovered, focused or dragged.
    /// One of `gain`, `gainFull`, `participation`, `coverage`, `highlights`, `shadows`, `blacks`.
    public let mask: String?
    public let cost: ParameterCost

    public var labelKey: String { "ctrl.\(id).label" }
    public var helpKey: String { "ctrl.\(id).help" }
    public var undoKey: String { "undo.\(id)" }

    public init(id: String, group: ParameterGroup, kind: ParameterKind = .float,
                range: ClosedRange<Double>? = nil, step: Double? = nil,
                default: ParameterDefault, format: ParameterFormat? = nil,
                scale: ParameterScale = .direct, origin: ParameterOrigin = .lower,
                domains: Set<InputDomain> = Set(InputDomain.allCases),
                options: [ParameterOption] = [],
                visibleWhen: ParameterCondition? = nil, capability: String? = nil,
                scope: ParameterScope = .whole, mask: String? = nil,
                cost: ParameterCost = .instant) {
        self.id = id
        self.group = group
        self.kind = kind
        self.range = range
        self.step = step
        self.default = `default`
        self.format = format
        self.scale = scale
        self.origin = origin
        self.domains = domains
        self.options = options
        self.visibleWhen = visibleWhen
        self.capability = capability
        self.scope = scope
        self.mask = mask
        self.cost = cost
    }

    public func allows(_ domain: InputDomain) -> Bool { domains.contains(domain) }

    public func option(_ id: String) -> ParameterOption? { options.first { $0.id == id } }

    /// `byDomain` resolved for one input domain; the other cases pass through.
    public func defaultValue(in domain: InputDomain) -> ParameterDefault {
        guard case .byDomain(let table) = `default` else { return `default` }
        guard let entry = table.first(where: { $0.domain == domain }) else { return .constant(.none) }
        return .constant(entry.value)
    }

    /// Visible in this domain and satisfying `visibleWhen`. `value` resolves the
    /// referenced parameters, defaults included (see `Recipe.conditionValue(_:)`).
    public func isVisible(in domain: InputDomain, value: (String) -> ParameterValue?) -> Bool {
        guard allows(domain) else { return false }
        return visibleWhen?.isSatisfied(value) ?? true
    }
}

// MARK: - Engine semantics

/// The value a render node consumes, derived from the value the recipe stores.
///
/// The recipe and the inspector always use the units declared in p7-adjustments
/// §2.3–§2.7 (`−100…+100`, `0…100%`, EV, stops, kelvin, CIRAWFilter amounts). Each
/// declaration states its own `scale`, so the readout format never decides an engine
/// unit:
///
/// - `.direct`: unchanged. EV, stops, kelvin, `develop.temperature`,
///   `develop.tint` (CIRAWFilter's `neutralTint`, which takes at least ±500).
/// - `.hundredth`: divided by 100. Percent controls, and signed level controls such as
///   `tone.shadows` or `color.saturation` (`−100…+100` → `−1…+1`).
/// - `.contrast`: `2^(value/100 · log2 1.6)`, i.e. `1.6^(value/100)`; 0 → 1 (C1 calls
///   the default 1, the inspector shows 0), +100 → 1.6, −100 → 0.625. The curve itself
///   stays with the renderer (T2).
extension ParameterDeclaration {
    /// `tone.contrast`'s multiplier at +100 (p7-adjustments §2.4 suggests `c ≈ 0.6…1.6`).
    public static let contrastMultiplierCeiling = 1.6

    public func engineValue(_ value: Double) -> Double {
        switch scale {
        case .direct:
            return value
        case .hundredth:
            return value / 100
        case .contrast:
            return Self.contrastMultiplier(for: value)
        }
    }

    /// The multiplier the engine's contrast node receives for a stored contrast value.
    public static func contrastMultiplier(for value: Double) -> Double {
        pow(contrastMultiplierCeiling, value / 100)
    }
}
