import SwiftUI

/// One look in the LUT library: a swatch, its name (tagged when the open
/// photo uses it), its spaces and size, and the two things to do with it:
/// set its spaces, remove it.
public struct LUTLibraryRow: View {
    private let name: String
    private let spaces: Text
    private let size: String
    private let isInUse: Bool
    private let onSpaces: () -> Void
    private let onRemove: () -> Void

    public init(name: String, spaces: Text, size: String, isInUse: Bool, onSpaces: @escaping () -> Void,
                onRemove: @escaping () -> Void) {
        self.name = name
        self.spaces = spaces
        self.size = size
        self.isInUse = isInUse
        self.onSpaces = onSpaces
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: Space.s3) {
            // Only a mark for the row; it does not preview the look.
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.38, blue: 0.62), Color(red: 0.93, green: 0.66, blue: 0.42)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 36, height: 24)
                .overlay { RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Color.hdr.line) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: name).font(.system(size: TypeScale.Size.control, weight: .semibold))
                        .foregroundStyle(Color.hdr.inkStrong).lineLimit(1).truncationMode(.tail)
                    if isInUse { HDRTag(Text("design.lut.inUse", bundle: .module), tint: .accent) }
                }
                Text("\(spaces)  ·  \(size)").font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted).lineLimit(1)
            }
            Spacer(minLength: Space.s2)
            Button(action: onSpaces) { Text("design.lut.spaces", bundle: .module) }
                .buttonStyle(CompactButtonStyle(kind: .link))
            Button(action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(.hdrIcon)
                .help(Text("design.lut.remove", bundle: .module))
                .accessibilityLabel(Text("design.lut.remove", bundle: .module))
        }
        .padding(.vertical, Space.s2)
        .accessibilityElement(children: .contain)
    }
}
