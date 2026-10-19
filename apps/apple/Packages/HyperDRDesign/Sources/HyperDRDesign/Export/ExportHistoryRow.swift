import SwiftUI

/// A button at the right of a row: its title, an optional symbol, whether it
/// can be pressed now.
public struct RowAction {
    public var title: Text
    public var systemImage: String?
    public var isEnabled: Bool
    /// Why the action is off, as a tooltip and an accessibility hint; shown
    /// only while it is off.
    public var disabledReason: Text?
    public var action: () -> Void

    /// The reason to show: only while the action is off.
    var reasonWhileOff: Text? { isEnabled ? nil : disabledReason }

    public init(title: Text, systemImage: String? = nil, isEnabled: Bool = true, disabledReason: Text? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.action = action
    }
}

/// One export of the photo in the export history: its thumbnail and number,
/// the file, tags ("Matches current", "Saved"), a line about how it was
/// made, a note when the engine fell back, and what can be done with it:
/// restore its settings (`primary`) and show or save the file (`secondary`).
public struct ExportHistoryRow: View {
    private let thumbnail: ThumbnailContent
    private let number: Int?
    private let fileName: String
    private let tags: [HDRTag]
    private let meta: Text
    private let note: Text?
    private let primary: RowAction?
    private let secondary: RowAction

    public init(thumbnail: ThumbnailContent, number: Int?, fileName: String, tags: [HDRTag] = [], meta: Text, note: Text? = nil,
                primary: RowAction?, secondary: RowAction) {
        self.thumbnail = thumbnail
        self.number = number
        self.fileName = fileName
        self.tags = tags
        self.meta = meta
        self.note = note
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Thumbnail(thumbnail, width: 60, height: 40)
                .overlay(alignment: .bottomLeading) {
                    if let number {
                        Text(verbatim: "#\(number)")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(Color.hdr.overlayInk)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.hdr.overlay, in: .rect(cornerRadius: 3))
                            .padding(3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: fileName).font(.system(size: TypeScale.Size.control, weight: .semibold))
                        .foregroundStyle(Color.hdr.inkStrong).lineLimit(1).truncationMode(.middle)
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in tag }
                }
                meta.font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    note.font(.hdr.caption).foregroundStyle(Color.hdr.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s2)
            VStack(alignment: .trailing, spacing: 6) {
                if let primary {
                    Button(action: primary.action) { label(primary) }
                        .buttonStyle(CompactButtonStyle(kind: .secondary))
                        .disabled(!primary.isEnabled)
                        .modifier(DisabledReason(reason: primary.reasonWhileOff))
                }
                Button(action: secondary.action) { label(secondary) }
                    .buttonStyle(CompactButtonStyle(kind: .link))
                    .disabled(!secondary.isEnabled)
                    .modifier(DisabledReason(reason: secondary.reasonWhileOff))
            }
        }
        .padding(.vertical, Space.s3)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func label(_ action: RowAction) -> some View {
        if let image = action.systemImage {
            Label { action.title } icon: { Image(systemName: image) }
        } else {
            action.title
        }
    }
}
