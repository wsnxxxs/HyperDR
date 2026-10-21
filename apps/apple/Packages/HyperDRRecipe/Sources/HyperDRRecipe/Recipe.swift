import Foundation

/// A LUT is identified by its contents, never by a path, so a saved recipe keeps
/// working when the file moves or the app's container changes (p7-adjustments §2.6).
public struct LUTReference: Codable, Equatable, Sendable {
    /// Stable identity of the LUT contents, `sha256:<hex>`.
    public let contentHash: String
    /// Security-scoped bookmark, when the LUT was opened from outside the app
    /// container. Additive: `contentHash` stays authoritative and is what the
    /// library matches on.
    public let bookmark: Data?
    /// Display name only; never used to resolve the LUT.
    public let name: String

    public init(contentHash: String, name: String, bookmark: Data? = nil) {
        self.contentHash = contentHash
        self.bookmark = bookmark
        self.name = name
    }
}

/// The values `PHAdjustmentData` carries, so this package never imports Photos.
public struct AdjustmentData: Equatable, Sendable {
    public let formatIdentifier: String
    public let formatVersion: String
    public let data: Data

    public init(formatIdentifier: String = Recipe.adjustmentFormatIdentifier,
                formatVersion: String = Recipe.adjustmentFormatVersion, data: Data) {
        self.formatIdentifier = formatIdentifier
        self.formatVersion = formatVersion
        self.data = data
    }
}

/// Recipe v1 (p7-adjustments §2, gpu-pipeline §3).
///
/// - Only values that differ from the declaration's default are stored, keyed by
///   parameter id.
/// - Values for parameter ids this build does not know are kept verbatim, so a
///   recipe written by a newer build survives a round trip.
/// - The envelope carries the input domain (the defaults depend on it), the HDR
///   source and the LUT reference. Those two ids never appear in `values`.
/// - JSON is written with sorted keys, so the same recipe always serializes to the
///   same bytes.
public struct Recipe: Equatable, Sendable {
    public static let currentVersion = 1
    /// `PHAdjustmentData.formatIdentifier` for recipes written by HyperDR.
    public static let adjustmentFormatIdentifier = "com.hyperdr.HyperDR.recipe"
    /// `PHAdjustmentData.formatVersion`.
    public static let adjustmentFormatVersion = "1"

    public static let hdrSourceID = "hdr.source"
    public static let lookID = "look.lut"

    public let version: Int
    public private(set) var inputDomain: InputDomain
    public private(set) var hdrSource: HDRSource
    public var look: LUTReference?
    /// Overrides for declared parameters other than `hdr.source` and `look.lut`.
    public private(set) var values: [String: ParameterValue]

    public init(version: Int = Recipe.currentVersion, inputDomain: InputDomain = .sdr,
                hdrSource: HDRSource? = nil, look: LUTReference? = nil,
                values: [String: ParameterValue] = [:]) {
        self.version = version
        self.inputDomain = inputDomain
        let requested = hdrSource ?? HDRSource.defaultSource(for: inputDomain)
        self.hdrSource = requested.domains.contains(inputDomain)
            ? requested : HDRSource.defaultSource(for: inputDomain)
        self.look = look
        self.values = values.filter { $0.key != Recipe.hdrSourceID && $0.key != Recipe.lookID }
    }

    // MARK: - Values

    /// A different photo replaces the source; the HDR source falls back to the new
    /// domain's default when it no longer applies. A camera Log look input falls
    /// back to the declaration's default outside RAW. Other stored values are
    /// kept: a value that does not apply to the new domain is simply not visible.
    public mutating func setInputDomain(_ domain: InputDomain) {
        inputDomain = domain
        if !hdrSource.domains.contains(domain) {
            hdrSource = HDRSource.defaultSource(for: domain)
        }
        if let input = values["look.input"]?.stringValue,
           let option = Adjustments.declaration("look.input")?.options.first(where: { $0.id == input }),
           !option.domains.contains(domain) {
            setValue(nil, for: "look.input")
        }
    }

    /// Returns false when the source does not apply to the current input domain.
    @discardableResult
    public mutating func setHDRSource(_ source: HDRSource) -> Bool {
        guard source.domains.contains(inputDomain) else { return false }
        hdrSource = source
        return true
    }

    /// The stored value, or `nil` when the parameter follows its default.
    /// `hdr.source` is the envelope's `hdrSource`; `look.lut` is the envelope's `look`.
    public func value(for id: String) -> ParameterValue? {
        switch id {
        case Recipe.hdrSourceID: return .string(hdrSource.rawValue)
        case Recipe.lookID: return look.map { .string($0.contentHash) }
        default: return values[id]
        }
    }

    /// The value a condition is tested against: stored override, else the
    /// declaration's default when it is a constant (`.fromSource` and `.auto` are
    /// only known to the renderer).
    public func conditionValue(_ id: String) -> ParameterValue? {
        if let stored = value(for: id) { return stored }
        guard let declaration = Adjustments.declaration(id) else { return nil }
        guard case .constant(let value) = declaration.defaultValue(in: inputDomain) else { return nil }
        return value
    }

    /// Stores an override, or clears it with `nil`. A value equal to the
    /// declaration's default is not stored.
    public mutating func setValue(_ value: ParameterValue?, for id: String) {
        switch id {
        case Recipe.hdrSourceID:
            guard let value else {
                hdrSource = HDRSource.defaultSource(for: inputDomain)
                return
            }
            guard let raw = value.stringValue, let source = HDRSource(rawValue: raw) else {
                assertionFailure("hdr.source takes an HDRSource option id, got \(value)")
                return
            }
            setHDRSource(source)
        case Recipe.lookID:
            assertionFailure("LUT references are set through `look`, as a content hash or bookmark")
        default:
            guard let value else {
                values[id] = nil
                return
            }
            if let declaration = Adjustments.declaration(id),
               declaration.defaultValue(in: inputDomain) == .constant(value) {
                values[id] = nil
            } else {
                values[id] = value
            }
        }
    }

    /// True when the parameter holds its default: no stored value, or a stored value
    /// equal to the declared constant default.
    public func isDefault(_ id: String) -> Bool {
        switch id {
        case Recipe.lookID:
            return look == nil
        case Recipe.hdrSourceID:
            return hdrSource == HDRSource.defaultSource(for: inputDomain)
        default:
            guard let stored = values[id] else { return true }
            guard let declaration = Adjustments.declaration(id) else { return false }
            return declaration.defaultValue(in: inputDomain) == .constant(stored)
        }
    }

    /// Parameters the inspector shows for this recipe: the domain applies and
    /// `visibleWhen` holds.
    public var visibleParameters: [ParameterDeclaration] { Adjustments.visible(in: self) }
}

// MARK: - Serialization

extension Recipe: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, inputDomain, hdrSource, look, values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Recipe.currentVersion
        let domain = try container.decodeIfPresent(InputDomain.self, forKey: .inputDomain) ?? .sdr
        let source = try container.decodeIfPresent(HDRSource.self, forKey: .hdrSource)
        let look = try container.decodeIfPresent(LUTReference.self, forKey: .look)
        let values = try container.decodeIfPresent([String: ParameterValue].self, forKey: .values) ?? [:]
        self.init(version: version, inputDomain: domain, hdrSource: source, look: look, values: values)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(inputDomain, forKey: .inputDomain)
        try container.encode(hdrSource, forKey: .hdrSource)
        try container.encodeIfPresent(look, forKey: .look)
        if !values.isEmpty { try container.encode(values, forKey: .values) }
    }
}

extension Recipe {
    /// Stable bytes: sorted keys, no pretty printing.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func jsonString(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ data: Data) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: data)
    }

    /// What to hand to `PHAdjustmentData`. Photos is not imported here.
    public func adjustmentData() throws -> AdjustmentData {
        AdjustmentData(data: try encoded())
    }

    /// Restores a recipe from `PHAdjustmentData`, or `nil` when the data belongs to
    /// another app or another format.
    public init?(adjustmentData: AdjustmentData) {
        guard adjustmentData.formatIdentifier == Recipe.adjustmentFormatIdentifier,
              adjustmentData.formatVersion == Recipe.adjustmentFormatVersion,
              let recipe = try? Recipe.decode(adjustmentData.data) else { return nil }
        self = recipe
    }
}
