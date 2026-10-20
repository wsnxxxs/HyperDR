/// The source's display-referred input domain, before any editing.
public enum InputDomain: String, Codable, CaseIterable, Sendable {
    case sdr, hdr, dual, rawEDR
}

public enum ParameterGroup: String, Codable, Sendable {
    case hdr, light, color, look, detail, local
}

public enum ParameterKind: String, Codable, Sendable {
    case float, floatOrAuto, bool, choice, reference
}

public enum ParameterValue: Codable, Equatable, Sendable {
    case number(Double), bool(Bool), string(String), none
}

public enum ParameterDefault: Codable, Equatable, Sendable {
    case constant(ParameterValue)
    case fromSource
    case auto
}

public enum ParameterFormat: String, Codable, Sendable {
    case ev, signed, percent, stops, kelvin, integer
}

public enum ParameterOrigin: String, Codable, Sendable { case zero, lower }
public enum ParameterScope: String, Codable, Sendable { case whole, hdrOnly, sdrOnly }
public enum ParameterCost: String, Codable, Sendable { case instant, redevelop, inference }

/// Names and fields follow p7-adjustments §2.2. Visibility expressions and capability
/// identifiers are carried as declarations; their UI evaluation belongs to P7-2.
public struct ParameterDeclaration: Codable, Equatable, Sendable {
    public let id: String
    public let group: ParameterGroup
    public let kind: ParameterKind
    public let range: ClosedRange<Double>?
    public let step: Double?
    public let `default`: ParameterDefault
    public let format: ParameterFormat?
    public let origin: ParameterOrigin
    public let domains: Set<InputDomain>
    public let visibleWhen: String?
    public let capability: String?
    public let scope: ParameterScope
    public let mask: String?
    public let cost: ParameterCost
    public var labelKey: String { "ctrl.\(id).label" }
    public var helpKey: String { "ctrl.\(id).help" }
    public var undoKey: String { "undo.\(id)" }

    public init(id: String, group: ParameterGroup, kind: ParameterKind = .float,
                range: ClosedRange<Double>? = nil, step: Double? = nil,
                default: ParameterDefault, format: ParameterFormat? = nil,
                origin: ParameterOrigin = .lower,
                domains: Set<InputDomain> = Set(InputDomain.allCases),
                visibleWhen: String? = nil, capability: String? = nil,
                scope: ParameterScope = .whole, mask: String? = nil,
                cost: ParameterCost = .instant) {
        self.id = id
        self.group = group
        self.kind = kind
        self.range = range
        self.step = step
        self.default = `default`
        self.format = format
        self.origin = origin
        self.domains = domains
        self.visibleWhen = visibleWhen
        self.capability = capability
        self.scope = scope
        self.mask = mask
        self.cost = cost
    }
}

/// P7-0 envelope. Editing fields and migrations are added with the processing nodes.
public struct Recipe: Codable, Equatable, Sendable {
    public let version: Int
    public init() { version = 1 }
}
