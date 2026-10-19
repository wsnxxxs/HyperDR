import SwiftUI

/// What `FormatCardGroup` shows for one format.
public struct FormatCardItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let name: Text
    public let detail: Text
    public let unavailableReason: Text?
    public let help: Text?

    public init(id: ID, name: Text, detail: Text, unavailableReason: Text? = nil, help: Text? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.unavailableReason = unavailableReason
        self.help = help
    }

    public var isAvailable: Bool { unavailableReason == nil }
}

/// A titled group of `FormatCard`s in a grid, one of them selected. A radio
/// group to VoiceOver; the arrow keys move the selection to the next
/// format that can be chosen.
public struct FormatCardGroup<ID: Hashable>: View {
    private let title: Text
    private let items: [FormatCardItem<ID>]
    @Binding private var selection: ID
    private let columns: Int

    public init(title: Text, items: [FormatCardItem<ID>], selection: Binding<ID>, columns: Int) {
        self.title = title
        self.items = items
        _selection = selection
        self.columns = max(columns, 1)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            title
                .font(.system(size: TypeScale.Size.caption, weight: .semibold))
                .foregroundStyle(Color.hdr.inkStrong)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2, alignment: .top), count: columns),
                      alignment: .leading, spacing: Space.s2) {
                ForEach(items) { item in
                    FormatCard(name: item.name, detail: item.detail, isSelected: item.id == selection,
                               unavailableReason: item.unavailableReason, help: item.help) {
                        selection = item.id
                    }
                }
            }
            .onMoveCommand { direction in
                if let next = Self.neighbor(of: selection, in: items, direction: direction) { selection = next }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    /// The format an arrow key moves to from `current`: the nearest one in
    /// list order, left / up before and right / down after, that can be
    /// chosen; nil at the ends or for an unknown `current`.
    static func neighbor(of current: ID, in items: [FormatCardItem<ID>], direction: MoveCommandDirection) -> ID? {
        guard let index = items.firstIndex(where: { $0.id == current }) else { return nil }
        switch direction {
        case .left, .up: return items[..<index].last(where: \.isAvailable)?.id
        case .right, .down: return items[(index + 1)...].first(where: \.isAvailable)?.id
        @unknown default: return nil
        }
    }
}
