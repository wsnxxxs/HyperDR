import SwiftUI

/// Every token on one page: colours, type, spacing, radii, shadows, control
/// sizes and the base styles. Used to check the conversion against the web
/// panel in both appearances; the previews below are the acceptance view.
public struct TokenGallery: View {
    public init() {}

    public var body: some View {
        ScrollView { sheet }.background(Color.hdr.surfacePage)
    }

    /// The page without its scroll view, so it can also be rendered whole.
    var sheet: some View {
            VStack(alignment: .leading, spacing: Space.s6) {
                Text(verbatim: "HyperDRDesign").font(.hdr.title).foregroundStyle(Color.hdr.inkStrong)
                colours
                typeScale
                HStack(alignment: .top, spacing: Space.s6) { spacing; radii }
                elevations
                controls
                motion
            }
            .padding(Layout.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.hdr.surfacePage)
    }

    // MARK: Colours

    private var colours: some View {
        GallerySection("Colours") {
            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(verbatim: group).font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: Space.s3)], alignment: .leading, spacing: Space.s3) {
                        ForEach(Palette.tokens.filter { $0.group == group }) { ColourSwatch(token: $0) }
                    }
                }
            }
        }
    }

    private var groups: [String] {
        Palette.tokens.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
    }

    // MARK: Type

    private var typeScale: some View {
        GallerySection("Type") {
            VStack(alignment: .leading, spacing: Space.s2) {
                specimen(.hdr.title, "title 18 semibold", "导出照片 Export photo")
                specimen(.hdr.heading, "heading 14 semibold", "画面调整 Adjustments")
                specimen(.hdr.body, "body 14", "打开一张照片，调整光线，保留高光的层次。")
                specimen(.hdr.controlLabel, "controlLabel 13 medium", "适应窗口 Fit")
                specimen(.hdr.control, "control 13", "仅调色 · HDR 增强")
                specimen(.hdr.caption, "caption 12", "RAW · SDR 预览（屏幕不支持 HDR）· 导出不受影响")
                specimen(.hdr.readout, "readout 12 tabular", "125% · +0.30 EV")
                specimen(.hdr.mono(), "mono 12", "HyperDR --encoding hlg --clamp-srgb")
            }
        }
    }

    private func specimen(_ font: Font, _ label: String, _ sample: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            Text(verbatim: label).font(.hdr.mono(11)).foregroundStyle(Color.hdr.inkMuted).frame(width: 170, alignment: .leading)
            Text(verbatim: sample).font(font).foregroundStyle(Color.hdr.inkStrong)
        }
    }

    // MARK: Geometry

    private var spacing: some View {
        GallerySection("Space") {
            ForEach(Array([Space.s1, Space.s2, Space.s3, Space.s4, Space.s5, Space.s6].enumerated()), id: \.offset) { index, value in
                HStack(spacing: Space.s3) {
                    Text(verbatim: "s\(index + 1)  \(Int(value))").font(.hdr.mono(11)).foregroundStyle(Color.hdr.inkMuted).frame(width: 60, alignment: .leading)
                    Rectangle().fill(Color.hdr.accentFill).frame(width: value, height: 12)
                }
            }
        }
    }

    private var radii: some View {
        GallerySection("Radius") {
            HStack(spacing: Space.s3) {
                ForEach([("xs", Radius.xs), ("sm/md", Radius.sm), ("standard", Radius.standard), ("lg", Radius.lg), ("xl", Radius.xl)], id: \.0) { name, value in
                    VStack(spacing: Space.s1) {
                        RoundedRectangle(cornerRadius: value).fill(Color.hdr.surfaceCard)
                            .overlay { RoundedRectangle(cornerRadius: value).strokeBorder(Color.hdr.lineStrong) }
                            .frame(width: 56, height: 56)
                        Text(verbatim: "\(name) \(Int(value))").font(.hdr.mono(11)).foregroundStyle(Color.hdr.inkMuted)
                    }
                }
            }
        }
    }

    private var elevations: some View {
        GallerySection("Elevation") {
            HStack(spacing: Space.s5) {
                ForEach(Array(Elevation.allCases.enumerated()), id: \.offset) { _, elevation in
                    Text(verbatim: "\(elevation)").font(.hdr.mono(11)).foregroundStyle(Color.hdr.inkMuted)
                        .frame(width: 86, height: 60)
                        .background(Color.hdr.surfaceCard, in: .rect(cornerRadius: Radius.lg))
                        .elevation(elevation)
                }
            }
            .padding(Space.s4)
        }
    }

    // MARK: Controls

    private var controls: some View {
        GallerySection("Controls") {
            HStack(spacing: Space.s3) {
                Button("导出 Export") {}.buttonStyle(.hdrPrimary)
                Button("完成 Done") {}.buttonStyle(.hdrSecondary)
                Button { } label: { Label("打开照片", systemImage: "folder") }.buttonStyle(.hdrGhost)
                Button { } label: { Label("Settings", systemImage: "gearshape") }.buttonStyle(.hdrIcon)
                Button("Disabled") {}.buttonStyle(.hdrPrimary).disabled(true)
                Button("Disabled") {}.buttonStyle(.hdrSecondary).disabled(true)
            }
            HStack(spacing: Space.s3) {
                ForEach([("compact", ControlMetrics.compact), ("regular", ControlMetrics.regular)], id: \.0) { name, height in
                    Text(verbatim: "\(name) \(Int(height))").font(.hdr.mono(11)).foregroundStyle(Color.hdr.inkMuted)
                        .padding(.horizontal, Space.s3).frame(height: height)
                        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.hdr.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3])) }
                }
                Text(verbatim: "Card").font(.hdr.control).foregroundStyle(Color.hdr.ink).hdrCard(padding: Space.s3)
                Text(verbatim: "Well").font(.hdr.control).foregroundStyle(Color.hdr.ink).hdrWell()
                Text(verbatim: "原图").hdrOverlayChip().padding(Space.s2).background(Color.hdr.previewBackdrop, in: .rect(cornerRadius: Radius.sm))
                HDRBadge()
            }
            HStack(spacing: Space.s4) {
                ForEach([("inspector wide", Layout.inspectorWidth), ("regular", Layout.inspectorWidthRegular), ("narrow", Layout.inspectorWidthNarrow)], id: \.0) { name, width in
                    Text(verbatim: "\(name) \(Int(width))").font(.hdr.mono(11)).foregroundStyle(Color.hdr.inkMuted)
                }
                Text(verbatim: "status bar \(Int(Layout.statusBarHeight)) · panel padding \(Int(Layout.panelPadding)) · dialog \(Int(Layout.dialogWidth))×\(Int(Layout.dialogHeight))")
                    .font(.hdr.mono(11)).foregroundStyle(Color.hdr.inkMuted)
            }
        }
    }

    private var motion: some View {
        GallerySection("Motion") {
            HStack(spacing: Space.s5) {
                Canvas { context, size in
                    // cubic-bezier(0.16, 1, 0.3, 1)
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addCurve(to: CGPoint(x: size.width, y: 0),
                                  control1: CGPoint(x: 0.16 * size.width, y: 0),
                                  control2: CGPoint(x: 0.3 * size.width, y: 0))
                    context.stroke(path, with: .color(.hdr.accent), lineWidth: 2)
                }
                .frame(width: 120, height: 60)
                .hdrWell(padding: Space.s2)
                Text(verbatim: "ease (0.16, 1, 0.3, 1) · fast \(Int(Motion.fast * 1000)) ms · standard \(Int(Motion.standard * 1000)) ms · slow \(Int(Motion.slow * 1000)) ms · off under Reduce Motion")
                    .font(.hdr.mono(11)).foregroundStyle(Color.hdr.inkMuted)
            }
        }
    }
}

private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(verbatim: title).font(.hdr.heading).foregroundStyle(Color.hdr.inkStrong)
            content
        }
    }
}

private struct ColourSwatch: View {
    let token: Palette.Token
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: Space.s2) {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(token.color)
                .frame(width: 36, height: 36)
                .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.hdr.line) }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: token.name).font(.hdr.caption).foregroundStyle(Color.hdr.inkStrong).lineLimit(1)
                Text(verbatim: hex).font(.hdr.mono(10)).foregroundStyle(Color.hdr.inkMuted)
                if let css = token.css { Text(verbatim: css).font(.hdr.mono(10)).foregroundStyle(Color.hdr.inkMuted).lineLimit(1) }
            }
        }
    }

    private var hex: String {
        let c = token.color.resolve(in: environment)
        func byte(_ linear: Float) -> Int {
            let v = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return Int((min(max(v, 0), 1) * 255).rounded())
        }
        let rgb = String(format: "#%02X%02X%02X", byte(c.linearRed), byte(c.linearGreen), byte(c.linearBlue))
        return c.opacity < 0.999 ? rgb + String(format: " %.0f%%", c.opacity * 100) : rgb
    }
}

#Preview("Tokens · Light", traits: .fixedLayout(width: 1180, height: 2000)) {
    TokenGallery().environment(\.colorScheme, .light)
}

#Preview("Tokens · Dark", traits: .fixedLayout(width: 1180, height: 2000)) {
    TokenGallery().environment(\.colorScheme, .dark)
}
