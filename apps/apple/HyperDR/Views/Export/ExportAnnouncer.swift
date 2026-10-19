import AppKit
import Observation

/// What VoiceOver hears of an export (M3 §19). The status card and the Dock
/// are out of sight for a VoiceOver user, so the moments that matter are
/// spoken once each: it starts, it ends and was saved, it ends but could not
/// be saved, it fails, it is stopped. Never a percentage or a stage, which
/// would talk over everything else; "finished" comes only after the file is
/// written, because the model reaches `succeeded` after the save.
@MainActor final class ExportAnnouncer {
    struct Announcement: Equatable {
        var text: String
        /// Failures and "not saved" must not be swallowed by other speech.
        var isHigh: Bool
    }

    private let model: EditorModel
    private let locale: Locale
    private let post: (Announcement) -> Void
    private var last: ExportState.Phase

    init(model: EditorModel, locale: Locale = .current, post: @escaping (Announcement) -> Void = ExportAnnouncer.speak) {
        self.model = model
        self.locale = locale
        self.post = post
        last = model.export.phase
    }

    /// Starts following the model's export.
    func start() { track() }

    nonisolated static func speak(_ announcement: Announcement) {
        var text = AttributedString(announcement.text)
        if announcement.isHigh { text.accessibilitySpeechAnnouncementPriority = .high }
        AccessibilityNotification.Announcement(text).post()
    }

    private func track() {
        withObservationTracking {
            _ = model.export.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.track()
            }
        }
    }

    private static func isInFlight(_ phase: ExportState.Phase) -> Bool {
        [.preparing, .running, .finishing, .saving].contains(phase)
    }

    private func update() {
        let phase = model.export.phase
        defer { last = phase }
        guard phase != last else { return }
        let wasInFlight = Self.isInFlight(last)
        if Self.isInFlight(phase) {
            if !wasInFlight { announceStart() }
        } else if phase == .succeeded || phase == .failed || phase == .cancelled, last != .succeeded, last != .failed, last != .cancelled {
            announceEnd(phase)
        }
    }

    private func format(_ id: String) -> String { AppStrings.string("enc.\(id).label", locale: locale) }

    private func announceStart() {
        let name = model.document?.name ?? ""
        post(Announcement(text: AppStrings.format("export.announce.started %@ %@", locale: locale, name, format(model.export.encodingID)),
                          isHigh: false))
    }

    private func announceEnd(_ phase: ExportState.Phase) {
        let export = model.export
        switch phase {
        case .succeeded:
            guard let result = export.result else { return }
            if export.saveFailure != nil || result.saved == nil {
                post(Announcement(text: AppStrings.format("export.announce.notSaved %@", locale: locale, result.fileName), isHigh: true))
            } else {
                let encoding = model.exportVersions.first { $0.id == result.export }?.encodingID ?? export.encodingID
                post(Announcement(text: AppStrings.format("export.announce.saved %@ %@", locale: locale, format(encoding),
                                                          Self.folderName(result.saved)), isHigh: false))
            }
        case .failed:
            let failure = export.failure ?? UserFacingError(code: "export_failed")
            post(Announcement(text: AppStrings.format("export.announce.failed %@", locale: locale,
                                                      ErrorText(failure).title(locale: locale)), isHigh: true))
        default:
            post(Announcement(text: AppStrings.string("export.announce.stopped", locale: locale), isHigh: false))
        }
    }

    /// The system's name for the folder (not its path): "Pictures", "图片".
    static func folderName(_ saved: SavedLocation?) -> String {
        guard let saved else { return "" }
        guard let url = saved.url else { return saved.folderLabel }
        return FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
    }
}
