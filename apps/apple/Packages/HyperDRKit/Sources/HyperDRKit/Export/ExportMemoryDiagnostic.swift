import Foundation

/// Retained on failed admission and logged publicly, without photo paths.
/// Hosts can localize check/phase and format the MiB fields on a result page.
public struct ExportMemoryDiagnostic: Sendable, Codable, Equatable {
    public enum Check: String, Sendable, Codable { case process, gpu }
    public enum Phase: String, Sendable, Codable { case planning, running }
    public let check: Check
    public let phase: Phase
    public let requiredBytes, availableBytes: Int
    public var requiredMiB: Double { Double(requiredBytes) / 1_048_576 }
    public var availableMiB: Double { Double(availableBytes) / 1_048_576 }
    public var shortfallMiB: Double { max(0, requiredMiB - availableMiB) }
    public var summary: String {
        String(format: "check=%@ phase=%@ required=%.1f MiB available=%.1f MiB shortfall=%.1f MiB",
               locale: Locale(identifier: "en_US_POSIX"), check.rawValue, phase.rawValue,
               requiredMiB, availableMiB, shortfallMiB)
    }
    static func gpuFailure(required: Int, recommended: Int) -> Self? {
        // Simulator returns zero when Metal supplies no recommendation.
        // Unknown is not a zero-byte limit; process admission still applies.
        guard recommended > 0, required > recommended else { return nil }
        return .init(check: .gpu, phase: .running, requiredBytes: required, availableBytes: recommended)
    }
}
