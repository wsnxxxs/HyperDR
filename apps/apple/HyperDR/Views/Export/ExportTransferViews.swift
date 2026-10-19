import HyperDRDesign
import SwiftUI

/// Dragging an export out of the history or result card, and sharing it
/// (parity batch 7 §1). Both hand over a copy of the version's retained file,
/// made when the receiver asks, so they work for every version, saved or not.
@MainActor enum ExportTransfer {
    /// Wraps the picture-and-name block of a row (or the result card's
    /// picture) as a drag source. The block reads as one element to VoiceOver.
    static func dragSource(model: EditorModel, version: String, thumbnail: ThumbnailState,
                           name: String) -> (AnyView) -> AnyView {
        guard let item = model.transferItem(for: version) else { return { $0 } }
        return { content in
            AnyView(content
                .draggable(item) { DragPreview(thumbnail: thumbnail, name: item.fileName) }
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text("history.drag.hint")))
        }
    }
}

/// What follows the pointer while a version is dragged: its small picture and
/// its name, like a file dragged in Finder.
private struct DragPreview: View {
    let thumbnail: ThumbnailState
    let name: String

    var body: some View {
        VStack(spacing: 4) {
            Thumbnail(thumbnail.content(), width: 60, height: 40)
            Text(verbatim: name).font(Font.hdr.caption).foregroundStyle(Color.hdr.overlayInk)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .hdrOverlayChip()
        }
    }
}

/// The share icon beside a version's "Show in Finder" / "Save As…". Off, with
/// the reason as its tooltip, while the version's file is not available.
struct ExportShareButton: View {
    let model: EditorModel
    let version: String
    let thumbnail: ThumbnailState

    var body: some View {
        if let item = model.transferItem(for: version) {
            ShareLink(item: item, preview: SharePreview(Text(verbatim: item.fileName), image: previewImage)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.hdrIcon)
            .help(Text("history.share"))
            .accessibilityLabel(Text("history.share.a11y \(item.fileName)"))
        } else {
            Button {} label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.hdrIcon)
                .disabled(true)
                .help(Text("history.fileMissing.help"))
                .accessibilityLabel(Text("history.share"))
                .accessibilityHint(Text("history.fileMissing.help"))
        }
    }

    private var previewImage: Image {
        if case .ready(let image) = thumbnail { return Image(decorative: image, scale: 2) }
        return Image(systemName: "photo")
    }
}

/// Why the last drag or share did not hand a file over (parity batch 7 §1.6).
struct ExportTransferNotice: View {
    let model: EditorModel
    @Environment(\.locale) private var locale

    var body: some View {
        if let failure = model.export.transferFailure {
            InspectorNotice(Text(verbatim: Self.sentence(failure, locale: locale)), style: .warning)
                .task(id: failure) { Self.announce(failure, locale: locale) }
        }
    }

    static func sentence(_ failure: TransferFailure, locale: Locale) -> String {
        AppStrings.format(failure.error.code == "source_missing" ? "history.transfer.failed %@" : "history.transfer.failedOther %@",
                          locale: locale, failure.fileName)
    }

    private static func announce(_ failure: TransferFailure, locale: Locale) {
        var text = AttributedString(sentence(failure, locale: locale))
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
    }
}
