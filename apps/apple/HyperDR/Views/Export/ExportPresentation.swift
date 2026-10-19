import Foundation
import HyperDRDesign

/// What the export views say for one state of the model, as plain values:
/// which cards make up the format groups, which of the four HEVC reasons a
/// key stands for, the parts of the status line, the progress bar's style,
/// and the titles of the toolbar's and the panel's buttons. The views only
/// draw what this decides, so every state of the design (M3 §2–§7) has a
/// test.
enum ExportPresentation {
    // MARK: Formats

    struct FormatGroup: Equatable {
        let titleKey: String
        let ids: [String]
        /// Two wide cards, or four narrow ones in a row (§3.2).
        var columns: Int { ids.count >= 4 ? 4 : 2 }
    }

    /// The card groups: HDR enhancement shows six formats in two groups,
    /// colour-only the two SDR ones (§3.2).
    static func groups(for workflow: Workflow) -> [FormatGroup] {
        switch workflow {
        case .hdr:
            [FormatGroup(titleKey: "export.group.anyScreen", ids: ["adaptive", "iso-gainmap-jpeg"]),
             FormatGroup(titleKey: "export.group.hdrOnly", ids: ["pq", "hlg", "avif-pq", "avif-hlg"])]
        case .colorOnly:
            [FormatGroup(titleKey: "export.group.format", ids: ["sdr-jpeg", "sdr-tiff"])]
        }
    }

    /// Which of the four HEVC reasons (§3.3) a model reason key stands for;
    /// anything else is the generic one.
    enum Reason: String { case hevc, main10, probe, generic }

    static func reason(_ blockerKey: String) -> Reason {
        switch blockerKey {
        case "err.server.hevc_unavailable": .hevc
        case "err.server.hevc_main10_unavailable": .main10
        case "err.server.hevc_probe_failed": .probe
        default: .generic
        }
    }

    /// The card's short reason, "No HEVC encoder".
    static func shortReasonKey(_ blockerKey: String) -> String {
        switch reason(blockerKey) {
        case .hevc: "export.unavailable.short.hevc"
        case .main10: "export.unavailable.short.main10"
        case .probe: "export.unavailable.short.probe"
        case .generic: "export.unavailable.short.generic"
        }
    }

    /// The full reason, which takes the format's name as its one `%@`.
    static func fullReasonKey(_ blockerKey: String) -> String {
        switch reason(blockerKey) {
        case .hevc: "export.unavailable.full.hevc %@"
        case .main10: "export.unavailable.full.main10 %@"
        case .probe: "export.unavailable.full.probe %@"
        case .generic: "export.unavailable.full.generic %@"
        }
    }

    /// Whether a blocker is about the chosen format's encoder (and so is
    /// worded with the format's name) and not one of the model's own
    /// sentences or an error's.
    static func isFormatReason(_ blockerKey: String) -> Bool { blockerKey.contains(".hevc_") }

    // MARK: Buttons

    /// The panel's main button: HDR "Export…", colour-only "Save JPEG…" /
    /// "Save TIFF…". The ellipsis goes in fixed-folder mode, where no save
    /// panel follows (§3.5), and with a result the user has adjusted past
    /// the button says "Export New Version…".
    static func primaryActionKey(encoding: String, asksForPlace: Bool) -> String {
        guard asksForPlace else { return "export.action.export" }
        switch encoding {
        case "sdr-jpeg": return "export.action.saveJPEG"
        case "sdr-tiff": return "export.action.saveTIFF"
        default: return "export.action.exportEllipsis"
        }
    }

    /// The toolbar's idle title: the same words without the ellipsis, since
    /// the button opens the panel (§2.1).
    static func toolbarTitleKey(encoding: String) -> String {
        switch encoding {
        case "sdr-jpeg": "export.toolbar.saveJPEG"
        case "sdr-tiff": "export.toolbar.saveTIFF"
        default: "editor.export"
        }
    }

    /// The window subtitle's last part (§2.2); nil adds nothing.
    static func documentStatusKey(_ status: DocumentStatus, isExporting: Bool) -> String? {
        if isExporting { return "docStatus.exporting" }
        switch status {
        case .waiting: return nil
        case .notExported: return "docStatus.notExported"
        case .modifiedSinceExport: return "docStatus.modified"
        case .exportedNotSaved: return "docStatus.exportedNotSaved"
        case .saved: return "docStatus.saved"
        }
    }

    // MARK: Progress

    /// How the bar is drawn: grey and still while stopping, a sweep while
    /// there is no estimate, held at 99 % when over, else the estimate's
    /// fraction (§6).
    static func progressStyle(isStopping: Bool, estimate: ExportEstimate?) -> ExportProgressStyle {
        if isStopping { return .stopped(estimate?.fraction ?? 0) }
        guard let estimate else { return .indeterminate }
        return estimate.isOverdue ? .overdue : .determinate(estimate.fraction)
    }

    /// The percentage shown: only with an estimate, never above 99 until
    /// the export is done.
    static func percent(estimate: ExportEstimate?, isDone: Bool) -> Double? {
        estimate.map { isDone ? 1 : min($0.fraction, ExportProgressStyle.overdueFraction) }
    }

    /// The parts of "<stage> · <elapsed> · <estimate>".
    struct StatusParts: Equatable {
        enum Remaining: Equatable { case first, overdue, soon, seconds(Int), minutes(Int), none }
        var stageKey: String
        var remaining: Remaining
    }

    static func statusParts(phase: ExportState.Phase, stage: String?, workflow: Workflow,
                            estimate: ExportEstimate?) -> StatusParts {
        let stageKey: String
        switch phase {
        case .saving: stageKey = "export.save.saving"
        case .idle, .preparing: stageKey = "export.stage.preparing"
        default:
            switch stage {
            case "decode": stageKey = "export.stage.decode"
            case "process": stageKey = workflow == .colorOnly ? "export.stage.processColor" : "export.stage.process"
            case "encode", "finalize": stageKey = "export.stage.encode"
            case "verify": stageKey = "export.stage.verify"
            default: stageKey = "export.stage.preparing"
            }
        }
        let remaining: StatusParts.Remaining
        if phase == .saving { remaining = .none }
        else if let estimate {
            if estimate.isOverdue { remaining = .overdue }
            else {
                switch estimate.remainingBucket {
                case .soon: remaining = .soon
                case .seconds(let seconds): remaining = .seconds(seconds)
                case .minutes(let minutes): remaining = .minutes(minutes)
                case nil: remaining = .none
                }
            }
        } else { remaining = .first }
        return StatusParts(stageKey: stageKey, remaining: remaining)
    }

    /// "0:21", "12:05".
    static func elapsedText(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: Result facts

    /// The peak of a result as its two numbers: the ratio to SDR white
    /// ("5.7") and the stops ("+2.5 EV"), both in `locale`.
    static func peak(stops: Double, locale: Locale) -> (ratio: String, stops: String) {
        let ratio = (pow(2, stops) * 10).rounded() / 10
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).locale(locale)
        let sign = stops >= 0 ? "+" : "−"
        return (ratio.formatted(number), sign + abs(stops).formatted(number) + " EV")
    }
}

// MARK: - Text

extension ExportPresentation {
    /// "Encoding · 0:21 elapsed · about 10 s left": the stage, the time since
    /// the export began and the estimate, in `locale`.
    static func statusLine(_ parts: StatusParts, elapsed: Double, locale: Locale) -> String {
        var pieces = [AppStrings.string(parts.stageKey, locale: locale)]
        pieces.append(AppStrings.format("export.elapsed %@", locale: locale, elapsedText(elapsed)))
        if let remaining = remainingText(parts.remaining, locale: locale) { pieces.append(remaining) }
        return pieces.joined(separator: " · ")
    }

    static func remainingText(_ remaining: StatusParts.Remaining, locale: Locale) -> String? {
        switch remaining {
        case .first: AppStrings.string("export.eta.first", locale: locale)
        case .overdue: AppStrings.string("export.eta.overdue", locale: locale)
        case .soon: AppStrings.string("export.eta.soon", locale: locale)
        case .seconds(let seconds):
            AppStrings.format("export.eta.seconds %@", locale: locale, seconds.formatted(.number.locale(locale)))
        case .minutes(let minutes):
            AppStrings.format("export.eta.minutes %@", locale: locale, minutes.formatted(.number.locale(locale)))
        case .none: nil
        }
    }

    /// "72%" in `locale`.
    static func percentText(_ fraction: Double, locale: Locale) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "Exporting 72% · about 10 s left", for the canvas capsule; "…" stands
    /// for a percentage not known yet.
    static func capsuleText(estimate: ExportEstimate?, parts: StatusParts, locale: Locale) -> String {
        let percent = percent(estimate: estimate, isDone: false).map { percentText($0, locale: locale) } ?? "…"
        let eta = remainingText(parts.remaining, locale: locale) ?? AppStrings.string(parts.stageKey, locale: locale)
        return AppStrings.format("exportLock.canvas %@ %@", locale: locale, percent, eta)
    }

    /// The file the export is making or made: the saved name, else the
    /// name picked in the save panel, else the suggested one.
    @MainActor static func fileName(for model: EditorModel) -> String {
        if let name = model.export.result?.fileName, !name.isEmpty { return name }
        if case .file(let url)? = model.export.destination { return url.lastPathComponent }
        return model.suggestedFileName
    }

    /// Why a copy did not reach its place. A place picked in the save panel and
    /// the fixed folder fail with the same code, but only the fixed folder is
    /// something to fix in Settings, so the wording follows the way of saving.
    static func saveFailureSentence(_ failure: UserFacingError, mode: Preferences.SaveMode, locale: Locale) -> String {
        mode == .folder || failure.code == "session_expired"
            ? ErrorText(failure).body(locale: locale) : AppStrings.string("export.save.failed", locale: locale)
    }

    /// "…/Pictures", the system's own name for the folder a copy was saved in
    /// ("…/图片" on a Chinese system) when the copy's URL is known; the label
    /// stored with the version otherwise.
    static func savedFolder(_ saved: SavedLocation?) -> String {
        guard let saved else { return "" }
        guard let url = saved.url else { return saved.folderLabel }
        let folder = url.deletingLastPathComponent()
        return "…/" + FileManager.default.displayName(atPath: folder.path)
    }

    /// "Pictures": where the export is going, for "DSC04127.jpg → Pictures".
    @MainActor static func folderName(for model: EditorModel) -> String {
        switch model.export.destination {
        case .file(let url)?: FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
        case .folder(let label)?: label
        case nil: ""
        }
    }
}

// MARK: - Panel

extension ExportPresentation {
    /// Which view the export panel shows for the model's phase (§3, §6, §7).
    enum PanelMode: Equatable {
        case settings, progress, result, failure

        init(phase: ExportState.Phase) {
            switch phase {
            case .idle, .cancelled: self = .settings
            case .preparing, .running, .finishing, .saving: self = .progress
            case .succeeded: self = .result
            case .failed: self = .failure
            }
        }

        /// The mode when the panel is opened again after the outcome was
        /// dismissed: a result that still matches the edits is shown (§5.16),
        /// unless the user came to export again.
        init(phase: ExportState.Phase, hasMatchingResult: Bool, wantsSettings: Bool) {
            self = phase == .idle && hasMatchingResult && !wantsSettings ? .result : Self(phase: phase)
        }

        /// The panel is 760 wide for the settings and 560 for the rest.
        var width: CGFloat { self == .settings ? 760 : 560 }
    }

    /// The footer's sentence for the blocker: a format reason is worded
    /// with the chosen format's name; any other key is its own sentence.
    static func blockerText(_ key: String, formatName: String, locale: Locale) -> String {
        guard isFormatReason(key) else { return AppStrings.string(key, locale: locale) }
        return AppStrings.format(fullReasonKey(key), locale: locale, formatName)
    }

    /// Whether the blocker is about the save folder, for the Open Settings
    /// link next to it.
    static func isFolderBlocker(_ key: String) -> Bool { key.contains(".export_folder_") }

    /// The pieces of a finished export's facts, as plain strings.
    struct ResultFacts: Equatable {
        var size: String
        var peak: (ratio: String, stops: String)?
        var isVerified: Bool
        var time: String

        static func == (a: Self, b: Self) -> Bool {
            a.size == b.size && a.peak?.ratio == b.peak?.ratio && a.peak?.stops == b.peak?.stops
                && a.isVerified == b.isVerified && a.time == b.time
        }
    }

    static func resultFacts(_ result: ExportResult, locale: Locale) -> ResultFacts {
        let bytes = result.byteCount.formatted(.byteCount(style: .file).locale(locale))
        let size = result.pixelSize.map { "\($0.width) × \($0.height) · \(bytes)" } ?? bytes
        let peak = result.headroomStops.map { peak(stops: $0, locale: locale) }
        let seconds = Int(result.elapsed.seconds.rounded())
        return ResultFacts(size: size, peak: peak, isVerified: result.selfVerified,
                           time: elapsedText(Double(seconds)))
    }
}

// MARK: - History

extension ExportPresentation {
    /// A history row's one line of facts: "Today 10:42 · HDR JPEG · 6000 × 4000
    /// · 18.4 MB · manual · this version has a frame".
    static func historyMeta(_ version: ExportVersion, locale: Locale) -> String {
        var parts: [String] = []
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        parts.append(formatter.string(from: version.createdAt))
        parts.append(AppStrings.string("enc.\(version.encodingID).label", locale: locale))
        if let size = version.pixelSize { parts.append("\(size.width) × \(size.height)") }
        parts.append(version.byteCount.formatted(.byteCount(style: .file).locale(locale)))
        if let model = version.modelName { parts.append(AppStrings.format("history.ai %@", locale: locale, model)) }
        else { parts.append(AppStrings.string("history.manual", locale: locale)) }
        if version.hasFrame { parts.append(AppStrings.string("history.framed", locale: locale)) }
        return parts.joined(separator: " · ")
    }
}
