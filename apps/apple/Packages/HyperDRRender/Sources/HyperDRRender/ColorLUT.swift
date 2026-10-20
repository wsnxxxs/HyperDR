import Foundation

public enum LUTSpace: UInt32, Hashable, Sendable {
    case sRGB, displayP3, rec709, hlg, pq, sLog3
    public var isSDR: Bool { rawValue <= LUTSpace.rec709.rawValue }
}

/// Immutable .cube table, red axis fastest. 1D and 3D, domains and input-range
/// headers follow the existing engine's semantics. Samples may lie outside [0,1].
public struct ColorLUT: Hashable, Sendable {
    public let id = UUID()
    public let title: String
    public let size: Int
    public let is3D: Bool
    public let domainMinimum: SIMD3<Float>
    public let domainMaximum: SIMD3<Float>
    public let values: [SIMD3<Float>]
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(cube: String) throws {
        var title = "", size = 0, is3D = true
        var low = SIMD3<Float>(repeating: 0), high = SIMD3<Float>(repeating: 1)
        var values: [SIMD3<Float>] = []
        for (lineNumber, original) in cube.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines).enumerated() {
            let line = original.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard let key = parts.first else { continue }
            func bad() -> RenderError { .invalidLUT("Invalid .cube line \(lineNumber + 1)") }
            func numbers(_ count: Int) throws -> [Float] {
                guard parts.count == count + 1 else { throw bad() }
                let result = parts.dropFirst().compactMap { Float($0) }
                guard result.count == count, result.allSatisfy(\.isFinite) else { throw bad() }
                return result
            }
            switch key {
            case "TITLE": title = parts.dropFirst().joined(separator: " ")
            case "LUT_1D_SIZE", "LUT_3D_SIZE":
                guard size == 0, parts.count == 2, let value = Int(parts[1]) else { throw bad() }
                is3D = key == "LUT_3D_SIZE"
                guard (2...(is3D ? 129 : 65536)).contains(value) else { throw bad() }
                size = value
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let v = try numbers(3), rgb = SIMD3(v[0], v[1], v[2])
                if key == "DOMAIN_MIN" { low = rgb } else { high = rgb }
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                let v = try numbers(2)
                low = SIMD3(repeating: v[0]); high = SIMD3(repeating: v[1])
            default:
                guard size > 0, parts.count == 3 else { throw bad() }
                let v = parts.compactMap { Float($0) }
                guard v.count == 3, v.allSatisfy(\.isFinite) else { throw bad() }
                values.append(SIMD3(v[0], v[1], v[2]))
                guard values.count <= (is3D ? size * size * size : size) else { throw bad() }
            }
        }
        guard size > 0, values.count == (is3D ? size * size * size : size),
              low.x < high.x, low.y < high.y, low.z < high.z else { throw RenderError.invalidLUT("Incomplete .cube or invalid domain") }
        self.title = title; self.size = size; self.is3D = is3D
        self.domainMinimum = low; self.domainMaximum = high; self.values = values
    }

    public init(contentsOf url: URL) throws {
        try self.init(cube: String(contentsOf: url, encoding: .utf8))
    }
}
