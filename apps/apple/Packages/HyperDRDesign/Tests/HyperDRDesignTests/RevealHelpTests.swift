import Foundation
import SwiftUI
import Testing
@testable import HyperDRDesign

private func text(_ key: String, _ language: String) -> String {
    let path = Bundle.module.path(forResource: language, ofType: "lproj")
    return (path.flatMap(Bundle.init(path:)) ?? .module).localizedString(forKey: key, value: "MISSING", table: nil)
}

private func sentence(_ language: String) -> String { text("design.export.showInFinder.unavailable", language) }

/// The reason a disabled "Show in Finder" gives is attached as the tooltip and
/// the VoiceOver hint (`DisabledReason`), and only while the button is off.
@Test func theRevealReasonIsGivenOnlyWhileTheButtonIsOff() {
    #expect(ExportRevealHelp.reason(canShow: false) != nil)
    #expect(ExportRevealHelp.reason(canShow: true) == nil)
    let off = RowAction(title: Text(verbatim: "Show"), isEnabled: false, disabledReason: ExportRevealHelp.unavailable) {}
    let on = RowAction(title: Text(verbatim: "Show"), isEnabled: true, disabledReason: ExportRevealHelp.unavailable) {}
    let none = RowAction(title: Text(verbatim: "Show"), isEnabled: false) {}
    #expect(off.reasonWhileOff != nil)
    #expect(on.reasonWhileOff == nil, "an enabled action has no reason")
    #expect(none.reasonWhileOff == nil, "an action without a reason has none to show")
}

@Test func theRevealReasonIsTranslatedAndPointsToSaveAs() {
    #expect(sentence("en") == "This version was saved in an earlier session, so HyperDR can’t show it. Drag it out, share it, or use Save As… to save it again.")
    #expect(sentence("zh-Hans") == "这一版是之前保存的，HyperDR 不能再显示它。可以直接拖出、共享，或用“另存为…”再存一次。")
    #expect(sentence("en").contains(text("design.export.saveAs", "en")))
    #expect(sentence("zh-Hans").contains(text("design.export.saveAs", "zh-Hans")))
}
