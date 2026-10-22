import SwiftUI

/// What the inspector's export card is about.
public enum ExportStatusKind {
    /// Running; writing to the chosen place counts as running.
    case running
    /// Being stopped.
    case stopping
    /// Done and saved; `savedTo` is where ("…/Pictures").
    case exported(savedTo: String)
    /// Done, but the chosen place could not be written.
    case saveFailed
    /// Failed; `title` is the failure's headline.
    case failed(title: Text)
}

/// The card at the top of the inspector while an export runs, and, once it
/// ends, what came of it. The card stays until the user closes it.
///
/// Running: a lock, the title, the file, the percentage when there is an
/// estimate, the bar, the status line, the note that adjusting is locked,
/// and Stop Export / Details. `emphasis` flashes the card (accent outline
/// and glow, the note in the accent) when the user touches something locked;
/// under Reduce Motion it only changes colour.
///
/// Ended: success and failure each have their own tint, the one line that
/// matters, and the one action that follows (Show in Finder, Save As…,
/// Details). A success that no longer matches the edits (`isStale`) carries
/// the same "Earlier edit" tag as the result view.
public struct ExportStatusCard: View {
    private let kind: ExportStatusKind
    private let fileName: String
    private let statusLine: Text?
    private let percent: Double?
    private let progress: ExportProgressStyle?
    private let emphasis: Bool
    private let isStale: Bool
    private let onStop: (() -> Void)?
    private let onDetails: () -> Void
    private let onSave: (() -> Void)?
    private let onShowInFinder: (() -> Void)?
    private let canShowInFinder: Bool
    private let onDismiss: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(kind: ExportStatusKind, fileName: String, statusLine: Text? = nil, percent: Double? = nil,
                progress: ExportProgressStyle? = nil, emphasis: Bool = false, isStale: Bool = false, onStop: (() -> Void)? = nil,
                onDetails: @escaping () -> Void, onSave: (() -> Void)? = nil,
                onShowInFinder: (() -> Void)? = nil, canShowInFinder: Bool = true, onDismiss: (() -> Void)? = nil) {
        self.kind = kind
        self.fileName = fileName
        self.statusLine = statusLine
        self.percent = percent
        self.progress = progress
        self.emphasis = emphasis
        self.isStale = isStale
        self.onStop = onStop
        self.onDetails = onDetails
        self.onSave = onSave
        self.onShowInFinder = onShowInFinder
        self.canShowInFinder = canShowInFinder
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .running, .stopping: running
            case .exported, .saveFailed, .failed: ended
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The tint over the opaque panel surface, not under it.
        .background(tint.background, in: .rect(cornerRadius: Radius.standard))
        .background(Color.hdr.surfacePanel, in: .rect(cornerRadius: Radius.standard))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.standard)
                .strokeBorder(flashing ? Color.hdr.accent : tint.line, lineWidth: flashing ? 2 : 1)
        }
        .shadow(color: flashing && !reduceMotion ? Color.hdr.accent.opacity(0.45) : .clear, radius: 6)
        .hdrAnimation(emphasis ? Motion.standard : Motion.slow, value: emphasis)
        .accessibilityElement(children: .contain)
    }

    private var isFailed: Bool { if case .failed = kind { true } else { false } }
    private var isStopping: Bool { if case .stopping = kind { true } else { false } }
    private var flashing: Bool { emphasis && !isEnded }
    private var isEnded: Bool {
        switch kind {
        case .running, .stopping: false
        default: true
        }
    }

    private var tint: (background: Color, line: Color) {
        switch kind {
        case .running, .stopping: (.hdr.selectedBackground, .hdr.selectedLine)
        case .exported, .saveFailed: (Color.hdr.success.opacity(0.07), Color.hdr.success.opacity(0.35))
        case .failed: (Color.hdr.danger.opacity(0.07), Color.hdr.danger.opacity(0.35))
        }
    }

    // MARK: Running

    @ViewBuilder private var running: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Color.hdr.accent).accessibilityHidden(true)
            (isStopping ? Text("design.export.stopping", bundle: .module) : Text("design.export.exporting", bundle: .module))
                .font(.system(size: TypeScale.Size.control, weight: .semibold))
                .foregroundStyle(Color.hdr.inkStrong)
            Text(verbatim: fileName)
                .font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let percent, !isStopping {
                Text(ExportToolbarButton.percent(percent)).font(.hdr.readout).foregroundStyle(Color.hdr.inkStrong)
            }
        }
        ExportProgressBar(progress: barStyle, height: 4)
        if let statusLine {
            statusLine.font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
        Text("design.export.lockNote", bundle: .module)
            .font(.system(size: TypeScale.Size.caption, weight: emphasis ? .semibold : .regular))
            .foregroundStyle(emphasis ? Color.hdr.accent : Color.hdr.ink)
            .fixedSize(horizontal: false, vertical: true)
            .hdrAnimation(Motion.standard, value: emphasis)
        HStack {
            Button { onStop?() } label: {
                isStopping ? Text("design.export.stopPending", bundle: .module) : Text("design.export.stop", bundle: .module)
            }
            .buttonStyle(CompactButtonStyle(kind: .stop))
            .disabled(isStopping || onStop == nil)
            Spacer(minLength: 0)
            Button(action: onDetails) { Text("design.export.viewDetails", bundle: .module) }
                .buttonStyle(CompactButtonStyle(kind: .plain))
        }
    }

    private var barStyle: ExportProgressStyle {
        if isStopping { return .stopped(ExportProgressStyle.clamp(percent ?? progress?.fraction ?? 0)) }
        return progress ?? percent.map { .determinate($0) } ?? .indeterminate
    }

    // MARK: Ended

    @ViewBuilder private var ended: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            endedIcon
            endedTitle
                .font(.system(size: TypeScale.Size.control, weight: .semibold))
                .foregroundStyle(Color.hdr.inkStrong)
            Text(verbatim: fileName)
                .font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .accessibilityLabel(Text("design.export.dismiss", bundle: .module))
            }
        }
        if isStale, !isFailed {
            HDRTag(Text("design.export.earlier", bundle: .module), systemImage: "clock", tint: .warn)
        }
        endedLine
        endedActions
    }

    @ViewBuilder private var endedIcon: some View {
        switch kind {
        case .failed:
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 12))
                .foregroundStyle(Color.hdr.danger).accessibilityHidden(true)
        default:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                .foregroundStyle(Color.hdr.success).accessibilityHidden(true)
        }
    }

    private var endedTitle: Text {
        if case .failed = kind { Text("design.export.failed", bundle: .module) } else { Text("design.export.exported", bundle: .module) }
    }

    @ViewBuilder private var endedLine: some View {
        switch kind {
        case .exported(let place):
            Text("design.export.savedTo \(place)", bundle: .module)
                .font(.hdr.caption).foregroundStyle(Color.hdr.ink)
        case .saveFailed:
            Text("design.export.saveFailedShort", bundle: .module)
                .font(.hdr.caption).foregroundStyle(Color.hdr.warn)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let title):
            title.font(.hdr.caption).foregroundStyle(Color.hdr.ink).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var endedActions: some View {
        HStack {
            switch kind {
            case .failed:
                Spacer(minLength: 0)
                Button(action: onDetails) { Text("design.export.viewDetails", bundle: .module) }
                    .buttonStyle(CompactButtonStyle(kind: .secondary))
            case .saveFailed:
                Button(action: onDetails) { Text("design.export.viewDetails", bundle: .module) }
                    .buttonStyle(CompactButtonStyle(kind: .plain))
                Spacer(minLength: 0)
                if let onSave {
                    Button(action: onSave) { Text("design.export.saveAs", bundle: .module) }
                        .buttonStyle(CompactButtonStyle(kind: .primary))
                }
            default:
                Button(action: onDetails) { Text("design.export.viewDetails", bundle: .module) }
                    .buttonStyle(CompactButtonStyle(kind: .plain))
                Spacer(minLength: 0)
                if let onShowInFinder {
                    Button(action: onShowInFinder) {
                        Label { Text("design.export.showInFinder", bundle: .module) } icon: { Image(systemName: "folder") }
                    }
                    .buttonStyle(CompactButtonStyle(kind: .link))
                    .disabled(!canShowInFinder)
                    .revealUnavailableHelp(!canShowInFinder)
                }
            }
        }
    }
}
