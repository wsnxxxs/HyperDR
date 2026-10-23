import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// The iPad sidebar's tabs: the dock's (HDR, Adjust, Style, any other group,
/// Crop, Frame) as one capsule of equal segments at the sidebar's top, so the
/// sidebar shows one tab's controls at a time, as the iPhone does, instead of
/// every group in one long column. A dot marks a tab with changes; holding a
/// group's tab shows the photo without it.
struct SidebarTabs: View {
    let groups: [DockGroup]
    @Binding var pane: EditorPane
    var cropOn = false
    let frameOn: Bool
    var onBypass: (AdjustmentGroupID, Bool) -> Void = { _, _ in }
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(groups) { tab in
                item(.group(tab.id), symbol: tab.isMerged ? "slider.horizontal.3" : AdjustmentSymbols.group(tab.id),
                     label: tab.isMerged ? Text("ios.adjust.tab") : AdjustmentText.group(tab.id),
                     marked: tab.isModified, mark: tab.id == .hdr ? Color.hdr.amber : Color.hdr.accent,
                     isCurrent: { if case .group(let group) = $0 { tab.contains(group) } else { false } })
                    .onLongPressGesture(minimumDuration: 0.35) {
                        for state in tab.states { onBypass(state.group, true) }
                    } onPressingChanged: { pressing in
                        if !pressing { for state in tab.states { onBypass(state.group, false) } }
                    }
            }
            item(.crop, symbol: "crop.rotate", label: Text("ios.crop.title"), marked: cropOn, mark: Color.hdr.accent)
            item(.frame, symbol: "photo.artframe", label: Text("ios.frame.title"), marked: frameOn, mark: .white)
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .animation(.smooth(duration: 0.25), value: pane)
        .sensoryFeedback(.selection, trigger: pane)
    }

    private func item(_ target: EditorPane, symbol: String, label: Text, marked: Bool, mark: Color,
                      isCurrent: (EditorPane) -> Bool = { _ in false }) -> some View {
        let isCurrent = pane == target || isCurrent(pane)
        return Button { pane = target } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .symbolVariant(isCurrent ? .fill : .none)
                label
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if isCurrent {
                    Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "tab", in: selection)
                }
            }
            .overlay(alignment: .topTrailing) {
                if marked {
                    Circle().fill(mark).frame(width: 5, height: 5).padding(.top, 7).padding(.trailing, 10)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
