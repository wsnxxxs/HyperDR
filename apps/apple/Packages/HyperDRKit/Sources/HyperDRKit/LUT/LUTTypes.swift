import Foundation
import HyperDREngine

public struct LUTID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HyperDRError(code: "lut_invalid", message: "Invalid LUT identifier")
        }
        self.rawValue = rawValue
    }
    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}
public enum LUTSpace: String, Sendable, Hashable, Codable, CaseIterable {
    case srgb, p3, rec709, hlg, pq
    case slog3SGamut3Cine = "slog3-sgamut3cine"
}
public struct LUTEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: LUTID
    public let name: String
    public var input: LUTSpace
    public var output: LUTSpace
    private enum CodingKeys: String, CodingKey {
        case id = "lutId", name = "lutName", input = "lutInput", output = "lutOutput"
    }
}
