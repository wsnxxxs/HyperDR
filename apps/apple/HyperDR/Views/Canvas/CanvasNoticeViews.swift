import HyperDRDesign
import SwiftUI

/// What the small chip at the canvas's foot says about the photo that is open:
/// that it was reopened at launch without its adjustments, or that its file
/// changed elsewhere and was read again. It fades by itself, unless the
/// pointer or VoiceOver is on it.
enum CanvasNotice: Equatable {
    case restored(hasHistory: Bool)
    case sourceReplaced(name: String)

    func title(locale: Locale) -> String {
        switch self {
        case .restored: AppStrings.string("restore.done.title", locale: locale)
        case .sourceReplaced: AppStrings.string("source.replaced.title", locale: locale)
        }
    }

    func body(locale: Locale) -> String {
        switch self {
        case .restored(let hasHistory):
            AppStrings.string(hasHistory ? "restore.done.bodyWithHistory" : "restore.done.body", locale: locale)
        case .sourceReplaced(let name): AppStrings.format("source.replaced.body %@", locale: locale, name)
        }
    }

    /// The sentence VoiceOver reads when the chip appears.
    func announcement(locale: Locale) -> String { "\(title(locale: locale)). \(body(locale: locale))" }
}

/// How long the chip stays: from appearing, and again after the pointer or
/// VoiceOver let go of it. Tests shorten both.
@MainActor enum CanvasNoticeTiming {
    static var lifetime: Duration = .seconds(6)
    static var afterPause: Duration = .seconds(3)
}

/// Where the notices' sentences go for VoiceOver. Tests put a recorder here.
@MainActor enum NoticeAnnouncement {
    static var deliver: (String, _ highPriority: Bool) -> Void = { text, high in
        var spoken = AttributedString(text)
        if high { spoken.accessibilitySpeechAnnouncementPriority = .high }
        AccessibilityNotification.Announcement(spoken).post()
    }

    static func post(_ text: String, highPriority: Bool = false) { deliver(text, highPriority) }
}

struct CanvasNoticeChip: View {
    let notice: CanvasNotice
    let dismiss: () -> Void

    @Environment(\.locale) private var locale
    @State private var hovering = false
    @State private var hasBeenPaused = false
    @AccessibilityFocusState private var spoken: Bool

    private var paused: Bool { hovering || spoken }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s2) {
            Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: notice.title(locale: locale)).font(Font.hdr.control).fontWeight(.semibold)
                Text(verbatim: notice.body(locale: locale)).font(Font.hdr.caption).foregroundStyle(Color.hdr.overlayMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused($spoken)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.hdrIcon)
                .accessibilityLabel(Text("restore.dismiss"))
        }
        .frame(maxWidth: 460, alignment: .leading)
        .hdrOverlayChip()
        .onHover { hovering = $0 }
        .onChange(of: paused) { _, now in if now { hasBeenPaused = true } }
        .task(id: paused) {
            guard !paused else { return }
            try? await Task.sleep(for: hasBeenPaused ? CanvasNoticeTiming.afterPause : CanvasNoticeTiming.lifetime)
            if !Task.isCancelled { dismiss() }
        }
        .task(id: notice) { NoticeAnnouncement.post(notice.announcement(locale: locale)) }
    }
}

/// The empty canvas explaining why it is empty: the photo it remembers could
/// not be found. It stays until a photo is opened or it is closed.
struct RestoreMissingNotice: View {
    let name: String?
    let dismiss: () -> Void
    @Environment(\.locale) private var locale

    static func title(name: String?, locale: Locale) -> String {
        guard let name, !name.isEmpty else { return AppStrings.string("restore.missing.unnamed", locale: locale) }
        return AppStrings.format("restore.missing.title %@", locale: locale, name)
    }

    /// The sentence VoiceOver reads once, when the model learns the photo is gone.
    static func announcement(name: String?, locale: Locale) -> String {
        "\(title(name: name, locale: locale)). \(AppStrings.string("restore.missing.body", locale: locale))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s2) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.hdr.warn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(name: name, locale: locale)).font(Font.hdr.controlLabel).foregroundStyle(Color.hdr.ink)
                Text("restore.missing.body").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.hdrIcon)
                .accessibilityLabel(Text("restore.dismiss"))
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

/// The photo's file cannot be found, or was changed by another app. Not a
/// dismissable notice: it states something that stays true until the file is
/// back (it goes by itself then) or the photo is opened again.
struct SourceMissingBanner: View {
    enum Kind { case missing, changed }
    var kind = Kind.missing
    /// A chosen file is being checked: the button waits for that to finish.
    var isChecking = false
    /// Locates the missing file, or opens the changed one again.
    let locate: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hdr.warn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .missing ? "source.missing.title" : "source.changed.title")
                    .font(Font.hdr.control).fontWeight(.semibold)
                Text(kind == .missing ? "source.missing.body" : "source.changed.body")
                    .font(Font.hdr.caption).foregroundStyle(Color.hdr.overlayMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Button(action: locate) {
                Text(kind == .changed ? "source.changed.reopen" : isChecking ? "source.missing.checking" : "source.missing.locate")
                    .font(.system(size: TypeScale.Size.caption, weight: .semibold))
                    .foregroundStyle(Color.hdr.overlayInk)
                    .padding(.horizontal, Space.s2)
                    .frame(height: BusyChip.height)
                    .background(hovered ? Color.hdr.overlayHover : .clear, in: .rect(cornerRadius: Radius.md))
                    .contentShape(.rect(cornerRadius: Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(isChecking)
            .onHover { hovered = $0 }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .hdrOverlayChip()
    }
}
