import SwiftUI

/// A line of explanation in the inspector, under a control it explains.
///
/// - `info`: plain muted text.
/// - `progress`: a small spinner before the text.
/// - `success`: a check mark in the accent before the text.
/// - `warning`: a warning triangle, on a `warnSoft` plate so it is noticed.
///
/// Text wraps to as many lines as it needs. The caller passes a `Text`, so
/// the words can come from the app's catalogue.
public struct InspectorNotice: View {
    public enum Style: Sendable { case info, progress, success, warning }

    private let text: Text
    private let style: Style

    public init(_ text: Text, style: Style = .info) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            icon
            text
                .font(.hdr.caption)
                .foregroundStyle(style == .info || style == .progress ? Color.hdr.inkMuted : Color.hdr.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(style == .warning ? EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9) : EdgeInsets())
        .background {
            if style == .warning { RoundedRectangle(cornerRadius: Radius.sm).fill(Color.hdr.warnSoft) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch style {
        case .info:
            EmptyView()
        case .progress:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.hdr.success)
                .accessibilityHidden(true)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.hdr.warn)
                .accessibilityHidden(true)
        }
    }
}
