import SwiftUI

/// A failed export: the headline, what to do, and, folded away, the
/// engine's own line for whoever has to find out why. The details start
/// open, one tap closes them.
public struct ExportFailureCard: View {
    private let title: Text
    private let message: Text
    private let detail: String?

    @State private var showsDetail = true

    public init(title: Text, message: Text, detail: String?) {
        self.title = title
        self.message = message
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 16)).foregroundStyle(Color.hdr.danger)
                    .accessibilityHidden(true)
                title.font(.system(size: TypeScale.Size.body + 1, weight: .semibold)).foregroundStyle(Color.hdr.inkStrong)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            message.font(.system(size: TypeScale.Size.caption + 0.5)).foregroundStyle(Color.hdr.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Button {
                    withHDRAnimation { showsDetail.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showsDetail ? 90 : 0))
                        Text("design.export.detail", bundle: .module)
                    }
                    .font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(showsDetail ? "design.group.expanded" : "design.group.collapsed", bundle: .module))
                if showsDetail {
                    Text(verbatim: detail)
                        .font(.hdr.mono(11)).foregroundStyle(Color.hdr.ink)
                        .textSelection(.enabled)
                        .lineLimit(3).truncationMode(.middle)
                        .padding(.horizontal, Space.s2).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.hdr.surfaceSunken, in: .rect(cornerRadius: Radius.sm))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hdrCard()
    }
}
