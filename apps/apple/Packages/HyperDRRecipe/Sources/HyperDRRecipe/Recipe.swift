/// The source's display-referred input domain, before any editing.
public enum InputDomain: String, Codable, CaseIterable, Sendable {
    case sdr, hdr, dual, rawEDR
}

public enum ParameterKind: String, Codable, Sendable {
    case scalar, boolean
}

public enum ParameterUnit: String, Codable, Sendable {
    case none, stops, kelvin, percent
}

/// Shared by render nodes and the controls that edit them. IDs are stable recipe keys.
public struct ParameterDeclaration: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ParameterKind
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let unit: ParameterUnit
    public let domains: Set<InputDomain>

    public init(id: String, kind: ParameterKind = .scalar, range: ClosedRange<Double>,
                defaultValue: Double, unit: ParameterUnit = .none,
                domains: Set<InputDomain> = Set(InputDomain.allCases)) {
        precondition(range.contains(defaultValue))
        self.id = id
        self.kind = kind
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
        self.domains = domains
    }
}

/// P7-0 envelope. Editing fields and migrations are added with the processing nodes.
public struct Recipe: Codable, Equatable, Sendable {
    public let version: Int
    public init() { version = 1 }
}
