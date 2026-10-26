import SwiftUI

/// A collapsible group of parameters (CSS `.parameter-group`, an HTML
/// `<details>`): a hairline above, a full-width header with an icon, the
/// title, an optional summary of the group's state and a chevron, then the
/// controls.
///
/// The header's title side is a button: click or, with keyboard navigation,
/// Space toggles the group. VoiceOver reads it as a heading with an expanded
/// or collapsed value. The caller owns `isExpanded`, so it can keep it per
/// window or across launches.
///
/// `accessory` sits in the header between the summary and the chevron,
/// outside the toggle: the HDR group's switch, a group's reset. The chevron
/// is always last, at the trailing edge, as on the sections inside a group,
/// so every fold mark lines up down the column.
///
/// A group that is not `collapsible` is a titled section: always open, its
/// header a heading with no chevron (the iPad sidebar, which shows one tab's
/// groups at a time, has nothing to fold away).
public struct ParameterGroup<Content: View, Accessory: View>: View {
    private let title: Text
    private let systemImage: String
    private let summary: Text?
    private let collapsible: Bool
    @Binding private var isExpanded: Bool
    private let content: Content
    private let accessory: Accessory
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    public init(_ title: Text, systemImage: String, summary: Text? = nil,
                isExpanded: Binding<Bool>, collapsible: Bool = true, @ViewBuilder content: () -> Content,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.systemImage = systemImage
        self.summary = summary
        self.collapsible = collapsible
        _isExpanded = isExpanded
        self.content = content()
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.hdr.line).frame(height: 1)
            header
            if isExpanded || !collapsible {
                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .clipped()
    }

    private func toggle() {
        withHDRAnimation { isExpanded.toggle() }
    }

    @ViewBuilder private var header: some View {
        if collapsible {
            HStack(spacing: Space.s2) {
                Button(action: toggle) {
                    GroupHeader(title: title, systemImage: systemImage, summary: summary)
                }
                .buttonStyle(GroupHeaderStyle(hovered: hovered))
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(Text(isExpanded ? "design.group.expanded" : "design.group.collapsed", bundle: .module))
                accessory
                Button(action: toggle) {
                    DisclosureChevron(isExpanded: isExpanded)
                        .frame(width: 16, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(hovered ? Color.hdr.surfaceHover : .clear)
            .contentShape(.rect)
            .onHover { hovered = isEnabled && $0 }
            .hdrAnimation(Motion.fast, value: hovered)
        } else {
            HStack(spacing: Space.s2) {
                SectionHeader(title: title, systemImage: systemImage)
                accessory
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}

/// The icon, the title and, at the trailing end of the title side, the
/// summary (a folded group's changes).
private struct GroupHeader: View {
    let title: Text
    let systemImage: String
    let summary: Text?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: TypeScale.Size.body))
                .foregroundStyle(Color.hdr.inkMuted)
                .frame(width: 18)
                .accessibilityHidden(true)
            title
                .font(.system(size: TypeScale.Size.control, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: Space.s2)
            if let summary {
                summary
                    .font(.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// A section's heading: the icon and the title in the heading face, at the
/// header's height, so the accessory lines up as on a collapsible group.
private struct SectionHeader: View {
    let title: Text
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: TypeScale.Size.body, weight: .medium))
                .foregroundStyle(Color.hdr.accent)
                .frame(width: 18)
                .accessibilityHidden(true)
            title.font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.hdr.inkStrong).lineLimit(1)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The header's title side: the whole height of the row, its ink brighter
/// while the row is hovered (the row draws the wash, CSS `summary:hover`).
private struct GroupHeaderStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        GroupHeaderBody(configuration: configuration, hovered: hovered)
    }
}

private struct GroupHeaderBody: View {
    let configuration: ButtonStyleConfiguration
    let hovered: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(!isEnabled ? Color.hdr.inkDisabled : hovered ? Color.hdr.inkStrong : Color.hdr.ink)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .contentShape(.rect)
    }
}

public extension ParameterGroup where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, summary: Text? = nil,
         isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(Text(title), systemImage: systemImage, summary: summary, isExpanded: isExpanded,
                  content: content, accessory: { EmptyView() })
    }
}
