import SwiftUI

/// One line of an export's result: "Size  6000 × 4000 · 18.4 MB".
public struct ExportFact {
    public var label: Text
    public var value: Text
    public var tone: FactRow.Tone
    public var monospaced: Bool

    public init(label: Text, value: Text, tone: FactRow.Tone = .normal, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.tone = tone
        self.monospaced = monospaced
    }
}

/// Why a disabled "Show in Finder" is disabled. The tooltip and the VoiceOver
/// hint say it, so a pointer or a screen reader learns what to do instead.
public enum ExportRevealHelp {
    public static var unavailable: Text { Text("design.export.showInFinder.unavailable", bundle: .module) }

    /// The explanation to attach to a "Show in Finder" button: only while it is off.
    static func reason(canShow: Bool) -> Text? { canShow ? nil : unavailable }
}

/// Gives a control that is off its reason: a tooltip and an accessibility
/// hint, both only while there is one.
struct DisabledReason: ViewModifier {
    let reason: Text?

    func body(content: Content) -> some View {
        if let reason { content.help(reason).accessibilityHint(reason) } else { content }
    }
}

extension View {
    /// Explains a "Show in Finder" button that is off.
    func revealUnavailableHelp(_ explain: Bool) -> some View {
        modifier(DisabledReason(reason: ExportRevealHelp.reason(canShow: !explain)))
    }
}

/// What the result card's last row says about saving.
public enum ExportSaveRow {
    /// Saved: the place ("Saved to …/Pictures") and a way to show it.
    case saved(Text, showInFinder: () -> Void, canShowInFinder: Bool = true)
    /// Being written to the chosen place.
    case saving
    /// Could not be written: what to tell the user, and Save As….
    case failed(Text, saveAs: () -> Void, openSettings: (() -> Void)? = nil)
}

/// The card in the export panel when an export is done: what was made, any
/// warnings from the engine's report, and whether it reached the chosen
/// place. `isStale` marks a result the user has adjusted past.
public struct ExportResultCard: View {
    private let thumbnail: ThumbnailContent
    private let fileName: String
    private let facts: [ExportFact]
    private let warnings: [Text]
    private let isStale: Bool
    private let saveRow: ExportSaveRow
    private let dragSource: ((AnyView) -> AnyView)?
    private let shareAccessory: AnyView?

    /// `dragSource` wraps the picture to make it draggable; `shareAccessory`
    /// sits beside the save row's button (the share control).
    public init(thumbnail: ThumbnailContent, fileName: String, facts: [ExportFact], warnings: [Text] = [], isStale: Bool = false,
                saveRow: ExportSaveRow, dragSource: ((AnyView) -> AnyView)? = nil, shareAccessory: AnyView? = nil) {
        self.dragSource = dragSource
        self.shareAccessory = shareAccessory
        self.thumbnail = thumbnail
        self.fileName = fileName
        self.facts = facts
        self.warnings = warnings
        self.isStale = isStale
        self.saveRow = saveRow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Color.hdr.success)
                    .accessibilityHidden(true)
                Text("design.export.exported", bundle: .module)
                    .font(.system(size: TypeScale.Size.body + 1, weight: .semibold)).foregroundStyle(Color.hdr.inkStrong)
                if isStale { HDRTag(Text("design.export.earlier", bundle: .module), systemImage: "clock", tint: .warn) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // The whole block is the drag source, and reads as one element.
            let block = HStack(alignment: .top, spacing: Space.s3) {
                Thumbnail(thumbnail, width: 96, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: fileName).font(.system(size: TypeScale.Size.control, weight: .semibold))
                        .foregroundStyle(Color.hdr.inkStrong).lineLimit(1).truncationMode(.middle)
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        FactRow(label: fact.label, value: fact.value, tone: fact.tone, monospaced: fact.monospaced)
                    }
                }
            }
            if let dragSource { dragSource(AnyView(block)) } else { block }
            if isStale {
                Text("design.export.staleNote", bundle: .module)
                    .font(.hdr.caption).foregroundStyle(Color.hdr.ink).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                InspectorNotice(warning, style: .warning)
            }
            Rectangle().fill(Color.hdr.line).frame(height: 1)
            saveView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hdrCard()
    }

    @ViewBuilder private var saveView: some View {
        switch saveRow {
        case .saved(let place, let showInFinder, let canShowInFinder):
            HStack {
                InspectorNotice(place, style: .success)
                Spacer(minLength: 0)
                Button(action: showInFinder) {
                    Label { Text("design.export.showInFinder", bundle: .module) } icon: { Image(systemName: "folder") }
                }
                .buttonStyle(CompactButtonStyle(kind: .link))
                .disabled(!canShowInFinder)
                .revealUnavailableHelp(!canShowInFinder)
                if let shareAccessory { shareAccessory }
            }
        case .saving:
            InspectorNotice(Text("design.export.saving", bundle: .module), style: .progress)
        case .failed(let message, let saveAs, let openSettings):
            VStack(alignment: .leading, spacing: Space.s2) {
                InspectorNotice(message, style: .warning)
                HStack {
                    if let openSettings {
                        Button(action: openSettings) { Text("design.export.openSettings", bundle: .module) }
                            .buttonStyle(CompactButtonStyle(kind: .link))
                    }
                    Spacer(minLength: 0)
                    if let shareAccessory { shareAccessory }
                    Button(action: saveAs) { Text("design.export.saveAs", bundle: .module) }
                        .buttonStyle(CompactButtonStyle(kind: .primary))
                }
            }
        }
    }
}
