import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// What the Studio panel shows: one adjustment group, the crop, or the
/// export's frame. On the iPad light and colour are tools of their own
/// (ipad-studio §3.3): the panel has the room, and each fits without scrolling.
enum PadTool: Hashable {
    case group(AdjustmentGroupID)
    case crop
    case frame

    var group: AdjustmentGroupID? {
        if case .group(let group) = self { return group }
        return nil
    }

    var symbol: String {
        switch self {
        case .group(let group): AdjustmentSymbols.group(group)
        case .crop: "crop.rotate"
        case .frame: "photo.artframe"
        }
    }

    var title: Text {
        switch self {
        case .group(let group): AdjustmentText.group(group)
        case .crop: Text("ios.crop.title")
        case .frame: Text("ios.frame.title")
        }
    }

    /// The tools for a recipe, in rail order: its groups, then the crop and
    /// the frame, which shape the picture and the export rather than its tones.
    static func tools(_ groups: [AdjustmentGroupState]) -> [PadTool] {
        groups.map { .group($0.group) } + [.crop, .frame]
    }
}

/// One tool on the rail, with whether it carries changes.
struct PadRailItem: Identifiable {
    let tool: PadTool
    let marked: Bool
    var id: PadTool { tool }

    /// HDR's changes are amber, the others' the accent; the frame is white
    /// while it is on.
    var mark: Color {
        switch tool {
        case .group(.hdr): Color.hdr.amber
        case .frame: .white
        default: Color.hdr.accent
        }
    }
}

/// The tool rail (ipad-studio §3.3): each tool's symbol over its name,
/// standing on the panel's outer edge or lying across its top. The current
/// tool is lit, a dot marks a tool with changes, and the frame and crop sit
/// apart after a hairline. Holding an adjustment tool shows the photo without
/// that group until it is let go (never undone). ⌘1, ⌘2 … pick the tools
/// in order; under a pointer a tool lights up.
struct PadToolRail: View {
    let items: [PadRailItem]
    let selection: PadTool
    let axis: Axis
    let choose: (PadTool) -> Void
    var onBypass: (AdjustmentGroupID, Bool) -> Void = { _, _ in }
    @Namespace private var highlight

    var body: some View {
        let stack = axis == .vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        stack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.tool == .crop {
                    divider
                }
                tile(item, index: index)
            }
        }
        .padding(axis == .vertical ? .vertical : .horizontal, 8)
        .animation(.smooth(duration: 0.25), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var divider: some View {
        Capsule()
            .fill(Color.white.opacity(0.14))
            .frame(width: axis == .vertical ? 28 : 1, height: axis == .vertical ? 1 : 28)
            .padding(axis == .vertical ? .vertical : .horizontal, 4)
    }

    private func tile(_ item: PadRailItem, index: Int) -> some View {
        let isCurrent = item.tool == selection
        return Button { choose(item.tool) } label: {
            VStack(spacing: 3) {
                Image(systemName: item.tool.symbol)
                    .font(.system(size: 19, weight: isCurrent ? .semibold : .regular))
                    .symbolVariant(isCurrent ? .fill : .none)
                    .frame(height: 24)
                item.tool.title
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            .frame(width: 64, height: 56)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "tool", in: highlight)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.marked {
                    Circle().fill(item.mark).frame(width: 6, height: 6).padding(.top, 7).padding(.trailing, 11)
                }
            }
            .contentShape(.rect(cornerRadius: 16))
            .contentShape(.hoverEffect, .rect(cornerRadius: 16))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
        .onLongPressGesture(minimumDuration: 0.35) {
            if let group = item.tool.group { onBypass(group, true) }
        } onPressingChanged: { pressing in
            if !pressing, let group = item.tool.group { onBypass(group, false) }
        }
        .accessibilityLabel(item.tool.title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
