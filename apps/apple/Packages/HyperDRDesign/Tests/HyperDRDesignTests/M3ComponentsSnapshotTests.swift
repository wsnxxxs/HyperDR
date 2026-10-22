import AppKit
import SwiftUI
import Testing
@testable import HyperDRDesign

private func png(_ bitmap: NSBitmapImageRep) throws -> Data {
    try #require(bitmap.representation(using: .png, properties: [:]))
}

/// The number of distinct pixel values sampled across the bitmap: a blank
/// or failed render has one or two.
private func distinctColours(_ bitmap: NSBitmapImageRep) -> Int {
    var seen = Set<UInt32>()
    let stepX = max(bitmap.pixelsWide / 97, 1), stepY = max(bitmap.pixelsHigh / 89, 1)
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
        }
    }
    return seen.count
}

private let variants: [(String, ColorScheme, ColorSchemeContrast, String)] = [
    ("light", .light, .standard, "en"), ("dark", .dark, .standard, "en"),
    ("light-contrast", .light, .increased, "en"), ("dark-contrast", .dark, .increased, "en"),
    ("light-zh-Hans", .light, .standard, "zh-Hans"), ("dark-zh-Hans", .dark, .standard, "zh-Hans"),
]

/// Renders the M3 components gallery in light, dark, Increase Contrast and
/// Chinese, and checks each render has something on it. With
/// $HDR_SNAPSHOT_DIR set, also writes `m3-components-<variant>.png` (formats,
/// toolbar button, progress), `m3-components-cards-<variant>.png` (status,
/// result and failure cards) and `m3-components-rows-<variant>.png` (history
/// and LUT library rows) there, for the design record in docs/design/.
@MainActor @Test func m3ComponentsSnapshots() throws {
    let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"]
    for (name, scheme, contrast, locale) in variants {
        let columns: [(String, AnyView)] = [
            ("", AnyView(M3ComponentsGallery().formatsColumn)),
            ("cards-", AnyView(M3ComponentsGallery().cardsColumn)),
            ("rows-", AnyView(M3ComponentsGallery().rowsColumn)),
        ]
        for (infix, column) in columns {
            let bitmap = try snapshot(column, scheme: scheme, contrast: contrast, locale: locale)
            #expect(distinctColours(bitmap) > 40, "\(infix)column blank: \(name)")
            if let directory {
                try png(bitmap).write(to: URL(fileURLWithPath: directory).appendingPathComponent("m3-components-\(infix)\(name).png"))
            }
        }
    }
}

/// Light and dark, English and Chinese are four different pictures.
@MainActor @Test func m3SnapshotsFollowAppearanceAndLanguage() throws {
    func data(_ scheme: ColorScheme, _ locale: String) throws -> Data {
        try png(snapshot(ExportStatusCard(kind: .running, fileName: "DSC04127.jpg", statusLine: Text(verbatim: "Encoding"),
                                          percent: 0.72, onStop: {}, onDetails: {}),
                         width: Layout.inspectorWidth, scheme: scheme, locale: locale))
    }
    let pictures = try [data(.light, "en"), data(.dark, "en"), data(.light, "zh-Hans"), data(.dark, "zh-Hans")]
    #expect(Set(pictures).count == 4)
}

/// Each state of a component is a picture of its own.
@MainActor @Test func m3StatesLookDifferent() throws {
    func card(_ selected: Bool, _ reason: Bool, disabled: Bool = false) throws -> Data {
        try png(snapshot(FormatCard(name: Text(verbatim: "HDR JPEG"), detail: Text(verbatim: "JPEG · ISO gain map"), isSelected: selected,
                                    unavailableReason: reason ? Text(verbatim: "No HEVC encoder") : nil, width: 200) {}
            .disabled(disabled)))
    }
    let cards = try [card(false, false), card(true, false), card(false, true), card(true, true), card(true, false, disabled: true)]
    #expect(Set(cards).count == cards.count, "normal, selected, unavailable, both and locked cards differ")

    func status(_ emphasis: Bool, _ kind: ExportStatusKind) throws -> Data {
        try png(snapshot(ExportStatusCard(kind: kind, fileName: "a.jpg", statusLine: Text(verbatim: "Encoding"), percent: 0.5,
                                          emphasis: emphasis, onStop: {}, onDetails: {}, onSave: {}, onShowInFinder: {}, onDismiss: {}),
                         width: Layout.inspectorWidth))
    }
    let statuses = try [status(false, .running), status(true, .running), status(false, .stopping), status(false, .exported(savedTo: "x")),
                        status(false, .saveFailed), status(false, .failed(title: Text(verbatim: "Too large")))]
    #expect(Set(statuses).count == statuses.count, "running, flashing, stopping, saved, not saved and failed cards differ")

    func result(_ stale: Bool, _ save: ExportSaveRow) throws -> Data {
        try png(snapshot(ExportResultCard(thumbnail: .unavailable, fileName: "a.jpg", facts: [], isStale: stale, saveRow: save), width: 400))
    }
    let results = try [result(false, .saved(Text(verbatim: "Saved"), showInFinder: {})), result(true, .saved(Text(verbatim: "Saved"), showInFinder: {})),
                       result(false, .saving), result(false, .failed(Text(verbatim: "No"), saveAs: {}))]
    #expect(Set(results).count == results.count)
}

/// The toolbar button does not change width between its states.
@MainActor @Test func exportToolbarButtonKeepsItsWidth() {
    func width(_ state: ExportButtonState) -> CGFloat {
        NSHostingView(rootView: ExportToolbarButton(state: state) {}).fittingSize.width
    }
    let widths = [
        width(.idle(title: Text(verbatim: "Export"))), width(.idle(title: Text(verbatim: "Save JPEG"))),
        width(.exporting(fraction: nil)), width(.exporting(fraction: 0.07)), width(.exporting(fraction: 0.72)),
        width(.exporting(fraction: 1)), width(.disabled(title: Text(verbatim: "Export"), reason: Text(verbatim: "x"))),
    ]
    #expect(Set(widths).count == 1, "widths: \(widths)")
    #expect(widths[0] > 100)
}

@Test func exportProgressFractionsAreClamped() {
    #expect(ExportProgressStyle.determinate(1.7).fraction == 1)
    #expect(ExportProgressStyle.determinate(-0.2).fraction == 0)
    #expect(ExportProgressStyle.determinate(.nan).fraction == 0)
    #expect(ExportProgressStyle.stopped(0.4).fraction == 0.4)
    #expect(ExportProgressStyle.overdue.fraction == 0.99)
    #expect(ExportProgressStyle.indeterminate.fraction == nil)
    #expect(ExportToolbarButton.percent(0.724) == "72%")
    #expect(ExportToolbarButton.percent(3) == "100%")
}

@MainActor @Test func arrowKeysMoveToTheNextFormatThatCanBeChosen() {
    let items = [
        FormatCardItem(id: 1, name: Text(verbatim: "a"), detail: Text(verbatim: "")),
        FormatCardItem(id: 2, name: Text(verbatim: "b"), detail: Text(verbatim: ""), unavailableReason: Text(verbatim: "no")),
        FormatCardItem(id: 3, name: Text(verbatim: "c"), detail: Text(verbatim: "")),
        FormatCardItem(id: 4, name: Text(verbatim: "d"), detail: Text(verbatim: "")),
    ]
    typealias Group = FormatCardGroup<Int>
    #expect(Group.neighbor(of: 1, in: items, direction: .right) == 3, "skips the unavailable one")
    #expect(Group.neighbor(of: 3, in: items, direction: .left) == 1)
    #expect(Group.neighbor(of: 1, in: items, direction: .down) == 3)
    #expect(Group.neighbor(of: 4, in: items, direction: .up) == 3)
    #expect(Group.neighbor(of: 1, in: items, direction: .left) == nil)
    #expect(Group.neighbor(of: 4, in: items, direction: .right) == nil)
    #expect(Group.neighbor(of: 2, in: items, direction: .right) == 3, "moves on from an unavailable selection")
    #expect(Group.neighbor(of: 9, in: items, direction: .right) == nil)
}

/// The colour of the pixel at (`x`, `y`) points from the top left of a
/// view of `width` points.
private func colour(_ bitmap: NSBitmapImageRep, width: CGFloat, x: CGFloat, y: CGFloat) throws -> NSColor {
    let scale = CGFloat(bitmap.pixelsWide) / width
    return try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
}

private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
}

/// The state's own fill must show: a point inside the card, away from its
/// border, text and check, has a different colour selected and not (a
/// picture that differs only in the border, text and check would pass
/// `m3StatesLookDifferent` with the fill covered).
@MainActor @Test func theSelectedFormatCardHasItsOwnFill() throws {
    for scheme in [ColorScheme.light, .dark] {
        func inside(selected: Bool, reason: Bool = false) throws -> NSColor {
            let bitmap = try snapshot(FormatCard(name: Text(verbatim: "HDR JPEG"), detail: Text(verbatim: "JPEG"), isSelected: selected,
                                                 unavailableReason: reason ? Text(verbatim: "No") : nil, width: 200) {},
                                      scheme: scheme)
            return try colour(bitmap, width: 200, x: 150, y: FormatCard.height - 12)
        }
        let normal = try inside(selected: false), selected = try inside(selected: true)
        #expect(distance(normal, selected) > 0.03, "selected and normal cards have one fill: \(scheme)")
        let unavailable = try inside(selected: false, reason: true)
        #expect(distance(normal, unavailable) > 0.01, "the unavailable card is sunken: \(scheme)")
    }
}

@MainActor @Test func theStatusCardsTintShows() throws {
    for scheme in [ColorScheme.light, .dark] {
        let panel = try colour(snapshot(Color.hdr.surfacePanel.frame(width: 20, height: 20), scheme: scheme),
                               width: 20, x: 10, y: 10)
        func inside(_ kind: ExportStatusKind) throws -> NSColor {
            let bitmap = try snapshot(ExportStatusCard(kind: kind, fileName: "a.jpg", statusLine: Text(verbatim: "Encoding"), percent: 0.5,
                                                       onStop: {}, onDetails: {}, onSave: {}, onShowInFinder: {}, onDismiss: {}),
                                      width: Layout.inspectorWidth, scheme: scheme)
            let scale = CGFloat(bitmap.pixelsWide) / Layout.inspectorWidth
            return try colour(bitmap, width: Layout.inspectorWidth, x: Layout.inspectorWidth - 6, y: CGFloat(bitmap.pixelsHigh) / scale / 2)
        }
        let kinds: [ExportStatusKind] = [.running, .stopping, .exported(savedTo: "x"), .saveFailed, .failed(title: Text(verbatim: "Too large"))]
        for kind in kinds {
            #expect(distance(panel, try inside(kind)) > 0.01, "\(kind) shows no tint over the panel: \(scheme)")
        }
    }
}

/// Moving by arrow key chooses a format and the group exposes itself as a
/// radio group, not a tab bar: a picture of the group still renders.
@MainActor @Test func theFormatGroupRendersWithItsRadioRepresentation() throws {
    var selection = 1
    let items = [FormatCardItem(id: 1, name: Text(verbatim: "a"), detail: Text(verbatim: "x")),
                 FormatCardItem(id: 2, name: Text(verbatim: "b"), detail: Text(verbatim: "y"), unavailableReason: Text(verbatim: "no"))]
    let group = FormatCardGroup(title: Text(verbatim: "Format"), items: items,
                                selection: Binding(get: { selection }, set: { selection = $0 }), columns: 2)
    let bitmap = try snapshot(group, width: 320)
    #expect(distinctColours(bitmap) > 10)
}
