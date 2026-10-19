import SwiftUI
import HyperDRDesign

/// "Preparing camera support…" while a RAW has waited 1.5 s for its first
/// frame (raw-states.md §2): macOS may be downloading support for the camera.
/// Without a photo on the canvas it fills the middle of it; over an earlier
/// photo it is a card at the bottom. Cancel goes back to what was there, with
/// no alert.
struct CameraSupportPanel: View {
    let fileName: String
    let canCancel: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Space.s3) {
            CanvasSpinner(size: 22)
            Text("raw.preparing.title")
                .font(.system(size: TypeScale.Size.body, weight: .semibold))
                .foregroundStyle(Color.hdr.overlayInk)
            Text(verbatim: fileName)
                .font(Font.hdr.readout)
                .foregroundStyle(Color.hdr.overlayMuted)
                .lineLimit(1).truncationMode(.middle)
            Text("raw.preparing.firstTime")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.overlayMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if canCancel {
                Button("open.cancel", action: cancel)
                    .buttonStyle(.hdrSecondary)
                    .keyboardShortcut(.cancelAction)
                    .help(Text("open.cancel.help"))
                    .accessibilityLabel(Text("open.cancel.a11y \(fileName)"))
                    .padding(.top, Space.s1)
            }
        }
        .frame(width: 320)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("raw.preparing.title"))
    }
}

struct CameraSupportCard: View {
    let fileName: String
    let canCancel: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.s4) {
            CanvasSpinner(size: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text("raw.preparing.title")
                        .font(.system(size: TypeScale.Size.control, weight: .semibold))
                        .foregroundStyle(Color.hdr.overlayInk)
                    Text(verbatim: fileName)
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.overlayMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("raw.preparing.short")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.overlayMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s3)
            if canCancel {
                Button("open.cancel", action: cancel)
                    .buttonStyle(.hdrSecondary)
                    .keyboardShortcut(.cancelAction)
                    .help(Text("open.cancel.help"))
                    .accessibilityLabel(Text("open.cancel.a11y \(fileName)"))
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: 480)
        .background(Color.hdr.overlay, in: .rect(cornerRadius: Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Color.hdr.overlayLine) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("raw.preparing.title"))
    }
}

/// What VoiceOver says when the prompt appears and when it is cancelled.
enum CameraSupportAnnouncement {
    static func post(_ key: String, locale: Locale, _ arguments: CVarArg...) {
        let text = arguments.isEmpty ? AppStrings.string(key, locale: locale)
            : String(format: AppStrings.string(key, locale: locale), locale: locale, arguments: arguments)
        AccessibilityNotification.Announcement(text).post()
    }
}
