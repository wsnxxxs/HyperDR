import Foundation

/// Retained on failed admission and logged publicly, without photo paths.
/// Hosts can localize check/phase and format the MiB fields on a result page.
public struct ExportMemoryDiagnostic: Sendable, Codable, Equatable {
    public enum Check: String, Sendable, Codable { case process, gpu }
    public enum Phase: String, Sendable, Codable { case planning, running }
    public enum Reason: String, Sendable, Codable { case workingSet, nonIncrementalWriter }
    public let reason: Reason
    public let check: Check
    public let phase: Phase
    public let requiredBytes, availableBytes: Int
    public init(check: Check, phase: Phase, requiredBytes: Int, availableBytes: Int, reason: Reason = .workingSet) {
        self.check = check; self.phase = phase; self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes; self.reason = reason
    }
    public var requiredMiB: Double { Double(requiredBytes) / 1_048_576 }
    public var availableMiB: Double { Double(availableBytes) / 1_048_576 }
    public var shortfallMiB: Double { max(0, requiredMiB - availableMiB) }
    public var summary: String {
        String(format: "check=%@ phase=%@ required=%.1f MiB available=%.1f MiB shortfall=%.1f MiB reason=%@",
               locale: Locale(identifier: "en_US_POSIX"), check.rawValue, phase.rawValue,
               requiredMiB, availableMiB, shortfallMiB, reason.rawValue)
    }
    static func gpuFailure(required: Int, recommended: Int) -> Self? {
        // Simulator returns zero when Metal supplies no recommendation.
        // Unknown is not a zero-byte limit; process admission still applies.
        guard recommended > 0, required > recommended else { return nil }
        return .init(check: .gpu, phase: .running, requiredBytes: required, availableBytes: recommended)
    }
}
