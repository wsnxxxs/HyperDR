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

/// What the result card's last row says about saving.
public enum ExportSaveRow {
    /// Saved: the place ("Saved to …/Pictures") and a way to show it.
    case saved(Text, showInFinder: () -> Void)
    /// Being written to the chosen place.
    case saving
    /// Could not be written: what to tell the user, and Save As….
    case failed(Text, saveAs: () -> Void)
}

/// The card in the export panel when an export is done: what was made, any
/// warnings from the engine's report, and whether it reached the chosen
/// place. `isStale` marks a result the user has adjusted past.
public struct ExportResultCard: View {
    private let thumbnail: Image?
    private let fileName: String
    private let facts: [ExportFact]
    private let warnings: [Text]
    private let isStale: Bool
    private let saveRow: ExportSaveRow

    public init(thumbnail: Image?, fileName: String, facts: [ExportFact], warnings: [Text] = [], isStale: Bool = false,
                saveRow: ExportSaveRow) {
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
            HStack(alignment: .top, spacing: Space.s3) {
                Thumbnail(image: thumbnail, width: 96, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: fileName).font(.system(size: TypeScale.Size.control, weight: .semibold))
                        .foregroundStyle(Color.hdr.inkStrong).lineLimit(1).truncationMode(.middle)
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        FactRow(label: fact.label, value: fact.value, tone: fact.tone, monospaced: fact.monospaced)
                    }
                }
            }
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
        case .saved(let place, let showInFinder):
            HStack {
                InspectorNotice(place, style: .success)
                Spacer(minLength: 0)
                Button(action: showInFinder) {
                    Label { Text("design.export.showInFinder", bundle: .module) } icon: { Image(systemName: "folder") }
                }
                .buttonStyle(CompactButtonStyle(kind: .link))
            }
        case .saving:
            InspectorNotice(Text("design.export.saving", bundle: .module), style: .progress)
        case .failed(let message, let saveAs):
            VStack(alignment: .leading, spacing: Space.s2) {
                InspectorNotice(message, style: .warning)
                HStack {
                    Spacer(minLength: 0)
                    Button(action: saveAs) { Text("design.export.saveAs", bundle: .module) }
                        .buttonStyle(CompactButtonStyle(kind: .primary))
                }
            }
        }
    }
}

/// A photo's thumbnail, or a quiet placeholder while there is none.
struct Thumbnail: View {
    let image: Image?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            Color.hdr.surfaceSunken
            if let image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: min(width, height) / 3))
                    .foregroundStyle(Color.hdr.inkDisabled)
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: Radius.sm))
        .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.hdr.line) }
        .accessibilityHidden(true)
    }
}
