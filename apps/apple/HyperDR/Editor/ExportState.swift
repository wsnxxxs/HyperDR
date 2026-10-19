import Foundation
import Observation

/// Editor-facing values. Views do not depend on Kit's jobs or durable manifests.
nonisolated enum EditingLockReason: String { case loading, restoring, computingAI, exporting }
nonisolated enum DocumentStatus { case waiting, notExported, modifiedSinceExport, exportedNotSaved, saved }
nonisolated enum ExportDestination: Equatable { case file(URL), folder(label: String) }
nonisolated struct SavedLocation: Equatable, Sendable {
    let fileName: String
    let folderLabel: String
    private let revealAction: (@MainActor @Sendable () -> Void)?
    init(fileName: String, folderLabel: String, reveal: (@MainActor @Sendable () -> Void)? = nil) {
        self.fileName = fileName; self.folderLabel = folderLabel; revealAction = reveal
    }
    var canReveal: Bool { revealAction != nil }
    @MainActor func reveal() { revealAction?() }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fileName == rhs.fileName && lhs.folderLabel == rhs.folderLabel && lhs.canReveal == rhs.canReveal
    }
    static func label(displayName: String?) -> String {
        guard let displayName, !displayName.isEmpty else { return String(localized: "export.location.unknown") }
        return "…/" + displayName
    }
}
nonisolated struct ExportResult: Equatable, Sendable {
    var export: String
    var fileName: String
    var byteCount: Int64
    var pixelSize: PixelSize?
    var headroomStops: Double? = nil
    var selfVerified = false
    var elapsed: Duration = .zero
    var warnings: [String] = []
    var saved: SavedLocation? = nil
}
nonisolated struct ExportFallbackReason: Equatable, Sendable {
    enum Code: String { case missingCaptureFields, unknown }
    var code: Code
    /// Engine field identifiers, never human-readable engine explanations.
    var missingCaptureFields: [String]
}
nonisolated struct ExportVersion: Identifiable, Equatable, Sendable {
    var id: String { result.export }
    var number: Int
    var createdAt: Date
    var encodingID: String
    var modelName: String? = nil
    var fallbackReason: ExportFallbackReason? = nil
    var hasFrame = false
    var matchesCurrent = false
    var result: ExportResult
    var fileName: String { result.fileName }
    var byteCount: Int64 { result.byteCount }
    var pixelSize: PixelSize? { result.pixelSize }
    var saved: SavedLocation? { result.saved }
}
nonisolated enum ExportSaveState: Equatable { case saving, saved(SavedLocation), expired, failed(UserFacingError) }

nonisolated struct ExportHistoryItem: Sendable {
    var version: ExportVersion
    var key: String
    var options: EditSnapshot
    var timing: ExportTimingSample?
}
nonisolated struct EditorExportTicket: Sendable { var job: String; var argv: [String] }
nonisolated enum EditorExportEvent: Sendable {
    case progress(stage: String, fraction: Double, at: Date)
    case log(String)
    case finishing, saving
    case finished(result: ExportResult?, failure: UserFacingError?)
}
nonisolated struct ExportEstimate: Equatable {
    enum RemainingBucket: Equatable { case soon, seconds(Int), minutes(Int) }
    var fraction: Double
    var remaining: Duration?
    var isOverdue: Bool
    var remainingBucket: RemainingBucket? {
        guard let remaining else { return nil }
        let seconds = max(0, remaining.seconds)
        if seconds < 5 { return .soon }
        if seconds < 60 { return .seconds(Int((seconds / 5).rounded(.up)) * 5) }
        return .minutes(Int((seconds / 60).rounded(.up)))
    }
}
nonisolated struct ExportTimingClass: Equatable, Sendable {
    var isRAW: Bool; var encoding: String; var isAI: Bool; var hasFrame: Bool; var verifies: Bool
}
nonisolated struct ExportTimingSample: Sendable {
    var kind: ExportTimingClass
    var pixels: Double
    /// Seconds in decode, process, encode, verify order.
    var stages: [Double]
}
/// No clock, observation or mutation: callers supply all inputs.
nonisolated enum ExportETA {
    static let stages = ["decode", "process", "encode", "verify"]
    static func durations(history: [ExportTimingSample], kind: ExportTimingClass, pixels: Double) -> [Double]? {
        let valid = history.filter { $0.pixels > 0 && $0.pixels.isFinite && $0.stages.count == 4
            && $0.stages.allSatisfy { $0.isFinite && $0 >= 0 } }
        let same = valid.filter { $0.kind == kind }
        let samples = same.isEmpty ? valid : same
        guard !samples.isEmpty, pixels > 0, pixels.isFinite else { return nil }
        return (0..<4).map { stage in
            let values = samples.map { $0.stages[stage] / $0.pixels }.sorted()
            let n = values.count
            let median = n.isMultiple(of: 2) ? (values[n/2-1] + values[n/2])/2 : values[n/2]
            return stage == 3 && !kind.verifies ? 0 : median * pixels
        }
    }
    static func estimate(at: Date, startedAt: Date, stageAt: Date, stage: String?, durations: [Double]?,
                         fractionFloor: Double, fraction: Double? = nil, fractionAt: Date? = nil, saving: Bool = false, completed: Bool = false) -> ExportEstimate? {
        if completed { return ExportEstimate(fraction: 1, remaining: .zero, isOverdue: false) }
        if saving { return ExportEstimate(fraction: 0.99, remaining: nil, isOverdue: false) }
        guard let durations else { return nil }
        let index = stages.firstIndex(of: stage ?? "decode") ?? 0
        let stageRemaining: Double
        // ABI2 emits real RAW block completion only in decode. process=.3,
        // encode=.7 and verify=.9 are whole-job milestones, not stage ratios.
        if stage == "decode", let fraction, fraction.isFinite, fraction > 0, fraction <= 1 {
            stageRemaining = max(0, durations[index] * (1 - fraction)
                - max(0, at.timeIntervalSince(fractionAt ?? stageAt)))
        } else {
            stageRemaining = max(0, durations[index] - max(0, at.timeIntervalSince(stageAt)))
        }
        let remaining = stageRemaining + durations.dropFirst(index + 1).reduce(0, +)
        let elapsed = max(0, at.timeIntervalSince(startedAt))
        let fraction = elapsed + remaining > 0 ? elapsed / (elapsed + remaining) : 0.99
        return ExportEstimate(fraction: min(0.99, max(fractionFloor, fraction)),
            remaining: .seconds(remaining), isOverdue: remaining <= 0)
    }
}
nonisolated extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

@MainActor @Observable final class ExportState {
    enum Phase: Equatable { case idle, preparing, running, finishing, saving, succeeded, failed, cancelled }
    var encodingID = "adaptive"
    var outputGamut = "srgb"
    var clampSrgb = false
    var phase: Phase = .idle
    var startedAt: Date?
    var stage: String?
    var fraction: Double?
    var lastLine: String?
    var failure: UserFacingError?
    var saveFailure: UserFacingError?
    var result: ExportResult?
    var isResultStale = false
    var blockerKey: String?
    var destination: ExportDestination?
    /// Every encoding id is present; a present optional nil means available.
    var encodingAvailability: [String: String?] = [:]
    var isStopping = false
    /// The user chose "Stop and Quit": the stop that follows is part of leaving,
    /// not a stop to announce (M3 §19.1). Set once the choice is made, before the
    /// cancellation starts; an export that finishes while the question was still
    /// open never sets it.
    @ObservationIgnored var isStoppingToQuit = false
    @ObservationIgnored var stageAt: Date?
    @ObservationIgnored var durations: [Double]?
    @ObservationIgnored var fractionFloor = 0.0
    @ObservationIgnored var fractionAt: Date?
    var isInFlight: Bool { [.preparing, .running, .finishing, .saving].contains(phase) }
    func estimate(at date: Date) -> ExportEstimate? {
        guard isInFlight || phase == .succeeded, let startedAt else { return nil }
        return ExportETA.estimate(at: date, startedAt: startedAt, stageAt: stageAt ?? startedAt,
            stage: stage, durations: durations, fractionFloor: fractionFloor, fraction: fraction, fractionAt: fractionAt,
            saving: phase == .saving || phase == .finishing, completed: phase == .succeeded)
    }
    func progress(stage newStage: String, fraction: Double, at date: Date) {
        if let current = ExportETA.stages.firstIndex(of: stage ?? ""),
           let next = ExportETA.stages.firstIndex(of: newStage), next < current { return }
        fractionFloor = max(fractionFloor, estimate(at: date)?.fraction ?? 0)
        if newStage != stage {
            stageAt = date; stage = newStage
            self.fraction = nil; fractionAt = nil
        }
        if fraction.isFinite, fraction > 0, fraction <= 1,
           newStage != "decode" || fraction > (self.fraction ?? 0) {
            self.fraction = fraction; fractionAt = date
        }
        phase = .running
    }
    func dismissOutcome() {
        guard !isInFlight else { return }
        phase = .idle; failure = nil; saveFailure = nil
    }
    func reset() {
        phase = .idle; startedAt = nil; stage = nil; fraction = nil; lastLine = nil
        failure = nil; saveFailure = nil; result = nil; isResultStale = false
        destination = nil; isStopping = false; isStoppingToQuit = false; durations = nil; fractionFloor = 0; fractionAt = nil; stageAt = nil
    }
}
nonisolated struct PhotoSwitchRequest: Equatable {
    enum Kind: Equatable { case open(URL), close }
    var kind: Kind
    var displayName: String
}

nonisolated enum PhotoSwitchPolicy: Equatable {
    case allowed, unavailable(reasonKey: String), confirmStoppingExport
}
