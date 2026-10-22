import SwiftUI

/// The type scale (CSS `--text-xs/-sm/-text/-lg`): 12 / 13 / 14 / 18 pt in the
/// system face. Captions 12, controls 13, body 14, titles 18. Headings are
/// semibold. The web's font fallback stack has no counterpart: SF and PingFang
/// are what the system face already resolves to.
public struct TypeScale: Sendable {
    fileprivate init() {}

    public enum Size {
        public static let caption: CGFloat = 12
        public static let control: CGFloat = 13
        public static let body: CGFloat = 14
        public static let title: CGFloat = 18
    }

    /// Hints, metadata, status bar.
    public var caption: Font { .system(size: Size.caption) }
    /// Buttons, fields, segmented controls.
    public var control: Font { .system(size: Size.control) }
    /// Button labels (CSS weight 500).
    public var controlLabel: Font { .system(size: Size.control, weight: .medium) }
    /// Body text.
    public var body: Font { .system(size: Size.body) }
    /// Section headings inside the inspector (14 pt semibold).
    public var heading: Font { .system(size: Size.body, weight: .semibold) }
    /// Dialog and page titles.
    public var title: Font { .system(size: Size.title, weight: .semibold) }
    /// Numeric readouts (zoom, slider values): monospaced digits.
    public var readout: Font { .system(size: Size.caption).monospacedDigit() }
    /// Command lines, file paths, keyboard shortcuts (CSS `--font-mono`).
    public func mono(_ size: CGFloat = Size.caption) -> Font { .system(size: size, design: .monospaced) }
}

public extension Font {
    /// HyperDR's type scale: `.font(.hdr.caption)`.
    static var hdr: TypeScale { TypeScale() }
}
