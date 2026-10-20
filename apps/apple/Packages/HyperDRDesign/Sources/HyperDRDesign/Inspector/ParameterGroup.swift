import SwiftUI

/// A collapsible group of parameters (CSS `.parameter-group`, an HTML
/// `<details>`): a hairline above, a full-width header with an icon, the
/// title, an optional summary of the group's state and a chevron, then the
/// controls.
///
/// The header is a button: click or, with keyboard navigation, Space toggles
/// the group. VoiceOver reads it as a heading with an expanded or collapsed
/// value. The caller owns `isExpanded`, so it can keep it per window or
/// across launches.
///
/// `accessory` sits at the header's trailing end, outside the toggle button:
/// the HDR group's switch, a group's reset. It brings its own trailing inset.
public struct ParameterGroup<Content: View, Accessory: View>: View {
    private let title: Text
    private let systemImage: String
    private let summary: Text?
    @Binding private var isExpanded: Bool
    private let content: Content
    private let accessory: Accessory

    public init(_ title: Text, systemImage: String, summary: Text? = nil,
                isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.systemImage = systemImage
        self.summary = summary
        _isExpanded = isExpanded
        self.content = content()
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.hdr.line).frame(height: 1)
            HStack(spacing: 0) {
                Button {
                    withHDRAnimation { isExpanded.toggle() }
                } label: {
                    GroupHeader(title: title, systemImage: systemImage, summary: summary, isExpanded: isExpanded)
                }
                .buttonStyle(GroupHeaderStyle())
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(Text(isExpanded ? "design.group.expanded" : "design.group.collapsed", bundle: .module))
                accessory
            }
            if isExpanded {
                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .clipped()
    }
}

private struct GroupHeader: View {
    let title: Text
    let systemImage: String
    let summary: Text?
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: TypeScale.Size.body))
                    .foregroundStyle(Color.hdr.inkMuted)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                title.lineLimit(1)
            }
            Spacer(minLength: 0)
            if let summary {
                summary.foregroundStyle(Color.hdr.inkMuted).lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.hdr.inkMuted)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .hdrAnimation(value: isExpanded)
                .accessibilityHidden(true)
        }
        .font(.hdr.caption)
    }
}

/// Full-width row, 15 × 20 padding, wash on hover (CSS `summary:hover`).
private struct GroupHeaderStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GroupHeaderBody(configuration: configuration)
    }
}

private struct GroupHeaderBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(!isEnabled ? Color.hdr.inkDisabled : hovered ? Color.hdr.inkStrong : Color.hdr.ink)
            .padding(.vertical, 15)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed ? Color.hdr.surfaceActive : hovered ? Color.hdr.surfaceHover : .clear)
            .contentShape(.rect)
            .onHover { hovered = isEnabled && $0 }
            .hdrAnimation(Motion.fast, value: hovered)
    }
}

public extension ParameterGroup where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, summary: Text? = nil,
         isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(Text(title), systemImage: systemImage, summary: summary, isExpanded: isExpanded,
                  content: content, accessory: { EmptyView() })
    }
}
