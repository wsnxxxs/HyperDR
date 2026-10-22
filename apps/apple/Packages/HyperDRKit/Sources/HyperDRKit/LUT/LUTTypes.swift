import Foundation
import HyperDREngine
import HyperDRRender

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
    case slog3SGamut3 = "slog3-sgamut3"
    case vlogVGamut = "vlog-vgamut"
    case flog2FGamut = "flog2-fgamut"
    case logC3AWG3 = "logc3-awg3"
    case logC4AWG4 = "logc4-awg4"
    case clog3CinemaGamut = "clog3-cinemagamut"
    public var renderSpace: HyperDRRender.LUTSpace {
        switch self {
        case .srgb: .sRGB
        case .p3: .displayP3
        case .rec709: .rec709
        case .hlg: .hlg
        case .pq: .pq
        case .slog3SGamut3Cine: .sLog3
        case .slog3SGamut3: .slog3SGamut3
        case .vlogVGamut: .vlogVGamut
        case .flog2FGamut: .flog2FGamut
        case .logC3AWG3: .logC3AWG3
        case .logC4AWG4: .logC4AWG4
        case .clog3CinemaGamut: .clog3CinemaGamut
        }
    }
}
public struct LUTEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: LUTID
    /// The Render/Recipe identity of the installed cube bytes; no re-parsing needed.
    public var contentHash: String { "sha256:" + id.rawValue }
    public let name: String
    public var input: LUTSpace
    public var output: LUTSpace
    /// Derived from the installed file, never trusted from metadata.
    public var byteCount: UInt64 = 0
    private enum CodingKeys: String, CodingKey {
        case id = "lutId", name = "lutName", input = "lutInput", output = "lutOutput"
    }
}
