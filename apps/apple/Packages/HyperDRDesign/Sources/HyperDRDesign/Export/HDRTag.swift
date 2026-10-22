import SwiftUI

/// The colour of an `HDRTag`.
public enum HDRTagTint: Sendable {
    case accent, success, warn

    var color: Color {
        switch self {
        case .accent: .hdr.accent
        case .success: .hdr.success
        case .warn: .hdr.warn
        }
    }
}

/// A small coloured capsule that labels a row: "Matches current", "Saved",
/// "Earlier edit". Not interactive.
public struct HDRTag: View {
    private let text: Text
    private let systemImage: String?
    private let tint: HDRTagTint

    public init(_ text: Text, systemImage: String? = nil, tint: HDRTagTint = .accent) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
            }
            text.font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.color.opacity(0.1), in: .rect(cornerRadius: Radius.xs))
        .overlay { RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(tint.color.opacity(0.35)) }
        .fixedSize()
    }
}
