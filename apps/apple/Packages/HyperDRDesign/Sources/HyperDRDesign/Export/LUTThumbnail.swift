import CoreGraphics
import SwiftUI

/// A library LUT as a square: its preview on the open photo when there is
/// one, otherwise a colour mark from its content hash, so each LUT keeps
/// one recognisable colour wherever it is listed. Without a hash it is the
/// look with no LUT: the photo as it is, or the no-entry mark.
public struct LUTThumbnail: View {
    private let image: CGImage?
    private let contentHash: String?
    private let side: CGFloat
    private let isSelected: Bool
    private let selection: Color

    public init(image: CGImage?, contentHash: String?, side: CGFloat, isSelected: Bool = false,
                selection: Color = Color.hdr.accent) {
        self.image = image
        self.contentHash = contentHash
        self.side = side
        self.isSelected = isSelected
        self.selection = selection
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: side >= 44 ? Radius.lg : Radius.xs)
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else if let contentHash {
                Rectangle().fill(Self.colour(contentHash).gradient)
            } else {
                Rectangle().fill(Color.hdr.surfaceSunken)
                Image(systemName: "nosign").foregroundStyle(Color.hdr.inkMuted)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay { shape.strokeBorder(isSelected ? selection : Color.hdr.line, lineWidth: isSelected ? 2 : 1) }
        .animation(.smooth(duration: 0.2), value: image != nil)
        .accessibilityHidden(true)
    }

    /// The colour mark of a content hash.
    public static func colour(_ hash: String) -> Color {
        let seed = hash.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return Color(hue: Double(seed % 360) / 360, saturation: 0.45, brightness: 0.7)
    }
}

extension EnvironmentValues {
    /// Told when a look picker (the inspector's, the dock's) appears and
    /// disappears, so the host renders LUT previews only while one is shown.
    @Entry public var lookPickerShown: @MainActor (Bool) -> Void = { _ in }
}

/// Explain unavailable camera Log LUTs beside the picker, before a selection.
public struct LUTCompatibilityNote: View {
    public init() {}

    public var body: some View {
        Label {
            Text("design.lut.requiresRAW", bundle: .module)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
