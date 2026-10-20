import Foundation
import CoreGraphics
import HyperDRKit
import HyperDRRender
import Observation

/// Editor-facing values. Views do not depend on Kit's jobs or durable manifests.
nonisolated enum EditingLockReason: String { case loading, restoring, exporting }
nonisolated enum DocumentStatus { case waiting, notExported, modifiedSinceExport, exportedNotSaved, saved }
nonisolated enum ThumbnailState: Equatable {
    case loading, ready(CGImage), unavailable
}
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
    /// The gamut written, as the planner resolved it; nil for versions from
    /// before recipe exports.
    var gamut: ExportColorGamut? = nil
    var modelName: String? = nil
    var fallbackReason: ExportFallbackReason? = nil
    var hasFrame = false
    var matchesCurrent = false
    /// The retained file can be read; when it cannot, the version can still be
    /// restored but not dragged, shared or saved again.
    var fileAvailable = true
    var result: ExportResult
    var fileName: String { result.fileName }
    var byteCount: Int64 { result.byteCount }
    var pixelSize: PixelSize? { result.pixelSize }
    var saved: SavedLocation? { result.saved }
}
nonisolated enum ExportSaveState: Equatable { case saving, saved(SavedLocation), expired, failed(UserFacingError) }

nonisolated struct ExportHistoryItem: Sendable {
    var version: ExportVersion
    /// What the version was made from: Kit's frozen recipe, source and frame,
    /// and the output it resolved to. Nil for versions written before recipe
    /// exports, which match no edit and restore only their format.
    var recipeSnapshot: RecipeExportSnapshot? = nil
    var resolved: ResolvedExportSnapshot? = nil
    /// The format the version was written in, as the panel shows it.
    var options: ExportChoices
    var timing: ExportTimingSample? = nil

    /// Whether exporting `snapshot` in `options` now would make this version
    /// again: the same recipe of the same file, the same frame, the same format.
    func matches(_ snapshot: RecipeExportSnapshot, options current: ExportChoices) -> Bool {
        guard let made = recipeSnapshot else { return false }
        return made.recipe == snapshot.recipe && made.source == snapshot.source && made.frame == snapshot.frame
            && options.customFormat == current.customFormat
    }
}
nonisolated struct EditorExportTicket: Sendable { var job: String }
/// One recipe export as the editor freezes it (P7-3b): the snapshot (recipe,
/// source revision, model, frame), Kit's plan request and the LUT the look
/// takes effect with.
nonisolated struct RecipeExportJob: Sendable {
    let snapshot: RecipeExportSnapshot
    let request: ExportPlanRequest
    let lut: ColorLUT?
}
nonisolated enum EditorExportEvent: Sendable {
    /// `message` is Kit's words for the stage (`RecipeExportProgress.stageMessage`),
    /// which can say more than `stage` (rendering and encoding on the row path).
    case progress(stage: String, fraction: Double, at: Date, message: ExportMessage? = nil)
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
    /// Seconds reading the photo (preparing, AI model, developing), rendering,
    /// encoding and verifying, in that order.
    var stages: [Double]
}
/// No clock, observation or mutation: callers supply all inputs.
nonisolated enum ExportETA {
    /// Kit's stages (`RecipeExportStage`) in the four spans the timing
    /// history keeps: preparing and the AI model count as reading the photo.
    static func span(_ stage: String?) -> Int? {
        switch stage {
        case "preparing", "model", "developing": 0
        case "rendering": 1
        case "encoding": 2
        case "verifying": 3
        default: nil
        }
    }
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
        let index = span(stage) ?? 0
        let stageRemaining: Double
        // Only rendering reports real progress: the rows Render has handed to
        // the writer. The other stages run on their history alone.
        if stage == "rendering", let fraction, fraction.isFinite, fraction > 0, fraction <= 1 {
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
    var thumbnail: ThumbnailState = .loading
    var encodingID = "adaptive"
    var outputGamut = "srgb"
    /// The gamut the export writes, as the planner resolves it.
    var gamut: ExportColorGamut = .p3
    var phase: Phase = .idle
    var startedAt: Date?
    var stage: String?
    /// Kit's words for the stage, shown in the status line.
    var stageMessage: ExportMessage?
    var fraction: Double?
    var lastLine: String?
    var failure: UserFacingError?
    var saveFailure: UserFacingError?
    /// Why the last drag or share of a version could not hand its file over.
    var transferFailure: TransferFailure?
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
    func progress(stage newStage: String, fraction: Double, at date: Date, message: ExportMessage? = nil) {
        let span = ExportETA.span(newStage)
        if let current = ExportETA.span(stage), let span, span < current { return }
        stageMessage = message ?? ExportMessage(key: "export.stage." + newStage)
        fractionFloor = max(fractionFloor, estimate(at: date)?.fraction ?? 0)
        if newStage != stage {
            // The AI model runs inside the photo's reading span: its clock goes on.
            if span != ExportETA.span(stage) { stageAt = date }
            stage = newStage
            self.fraction = nil; fractionAt = nil
        }
        if newStage == "rendering", fraction.isFinite, fraction > 0, fraction <= 1, fraction > (self.fraction ?? 0) {
            self.fraction = fraction; fractionAt = date
        }
        phase = .running
    }
    func dismissOutcome() {
        guard !isInFlight else { return }
        phase = .idle; failure = nil; saveFailure = nil
    }
    func reset() {
        thumbnail = .loading
        phase = .idle; startedAt = nil; stage = nil; stageMessage = nil; fraction = nil; lastLine = nil
        failure = nil; saveFailure = nil; transferFailure = nil; result = nil; isResultStale = false
        destination = nil; isStopping = false; isStoppingToQuit = false; durations = nil; fractionFloor = 0; fractionAt = nil; stageAt = nil
    }
}
nonisolated struct TransferFailure: Equatable {
    var version: String
    var fileName: String
    var error: UserFacingError
}
nonisolated struct PhotoSwitchRequest: Equatable {
    enum Kind: Equatable { case open(URL), close }
    var kind: Kind
    var displayName: String
}

nonisolated enum PhotoSwitchPolicy: Equatable {
    case allowed, unavailable(reasonKey: String), confirmStoppingExport
}
