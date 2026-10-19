import XCTest
@testable import HyperDR

/// The About page's rows (P-13): the engine, the models, the export memory
/// limit, the HDR preview and this Mac, in both languages.
@MainActor final class SettingsDiagnosticsTests: XCTestCase {
    private let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")

    private func display(current: Double, potential: Double) -> DisplayState {
        DisplayState(screenName: "Studio Display", currentHeadroom: current, potentialHeadroom: potential, gainWeight: nil)
    }

    func testTheEngineRowSaysReadyWithTheVersionAndInterface() {
        let model = EditorModel(services: FakeEditorServices())
        model.preferences.about.engineABI = 3
        XCTAssertEqual(SettingsDiagnostics.engine(model, locale: en), "Ready · version fixture-v1 · interface 3")
        XCTAssertEqual(SettingsDiagnostics.engine(model, locale: zh), "就绪 · 版本 fixture-v1 · 接口 3")
    }

    func testTheEngineRowSaysWhyTheEngineIsNotAvailable() {
        let services = FakeEditorServices()
        services.engineStatus = .failed(UserFacingError(code: "engine_unavailable"))
        let model = EditorModel(services: services)
        let title = ErrorText(UserFacingError(code: "engine_unavailable")).title(locale: en)
        XCTAssertEqual(SettingsDiagnostics.engine(model, locale: en), "Not available · " + title)
        XCTAssertTrue(SettingsDiagnostics.engine(model, locale: zh).hasPrefix("不可用 · "))
    }

    func testTheModelRowNamesEachModelWithItsVersion() {
        let services = FakeEditorServices()
        services.models.models = services.models.models.map { choice in
            var choice = choice; choice.version = "research-demo-fold0-seed908/v1"; return choice
        }
        let model = EditorModel(services: services)
        XCTAssertEqual(SettingsDiagnostics.models(model, locale: en), "Image-only CNN v1, EXIF-assisted prediction v1")
        XCTAssertEqual(SettingsDiagnostics.models(model, locale: zh), "纯 CNN v1和EXIF 参数辅助预测 v1")
    }

    func testTheModelRowSaysTheRuntimeIsMissing() {
        let services = FakeEditorServices()
        services.models = .unavailable
        let model = EditorModel(services: services)
        XCTAssertEqual(SettingsDiagnostics.models(model, locale: en), "Not available · this build has no model runtime")
        XCTAssertEqual(SettingsDiagnostics.models(model, locale: zh), "不可用 · 此版本没有包含模型运行时")
    }

    func testAModelWithoutAVersionIsListedByName() {
        XCTAssertNil(SettingsDiagnostics.shortVersion(nil))
        XCTAssertNil(SettingsDiagnostics.shortVersion(""))
        XCTAssertEqual(SettingsDiagnostics.shortVersion("v2"), "v2")
        XCTAssertEqual(SettingsDiagnostics.shortVersion("a/b/v3"), "v3")
    }

    func testTheHDRPreviewHasThreeStates() {
        XCTAssertEqual(SettingsDiagnostics.previewState(display(current: 2, potential: 4)), .hdr)
        XCTAssertEqual(SettingsDiagnostics.previewState(display(current: 1, potential: 1)), .sdrDisplay)
        XCTAssertEqual(SettingsDiagnostics.previewState(display(current: 1, potential: 4)), .noHeadroom)
        XCTAssertEqual(SettingsDiagnostics.preview(display(current: 2, potential: 4), locale: en), "Showing in HDR")
        XCTAssertEqual(SettingsDiagnostics.preview(display(current: 1, potential: 1), locale: en),
                       "Showing in SDR: this display doesn’t support HDR")
        XCTAssertEqual(SettingsDiagnostics.preview(display(current: 1, potential: 4), locale: zh),
                       "以 SDR 显示：屏幕目前没有 HDR 余量（亮度设置或低电量模式）")
    }

    func testTheExportMemoryLimitIsShownOnlyWhenTheEngineReportsOne() {
        let model = EditorModel(services: FakeEditorServices())
        XCTAssertNil(SettingsDiagnostics.memoryBudget(model, locale: en))
        model.preferences.about.memoryBudgetBytes = 0
        XCTAssertNil(SettingsDiagnostics.memoryBudget(model, locale: en))
        model.preferences.about.memoryBudgetBytes = 12 * 1_073_741_824
        XCTAssertEqual(SettingsDiagnostics.memoryBudget(model, locale: en), "12 GB")
        XCTAssertEqual(SettingsDiagnostics.memoryBudget(model, locale: zh), "12 GB")
    }

    func testThisMacRowJoinsTheSystemChipAndMemory() {
        XCTAssertEqual(SettingsDiagnostics.machine(system: "macOS 27.0.1", chip: "Apple M4 Pro",
                                                   memoryBytes: 48 * 1_073_741_824, locale: en),
                       "macOS 27.0.1 · Apple M4 Pro · 48 GB memory")
        XCTAssertEqual(SettingsDiagnostics.machine(system: "macOS 27.0.1", chip: "Apple M4 Pro",
                                                   memoryBytes: 48 * 1_073_741_824, locale: zh),
                       "macOS 27.0.1 · Apple M4 Pro · 48 GB 内存")
        XCTAssertTrue(SettingsDiagnostics.machine(system: "macOS 27.0.1", chip: nil, memoryBytes: 1 << 33, locale: en)
            .contains("Apple silicon"))
        XCTAssertTrue(SettingsDiagnostics.machine(locale: en).hasPrefix("macOS "))
    }

    func testTheCopiedDiagnosticsCarryTheNewRowsInEnglish() async {
        let model = EditorModel(services: FakeEditorServices())
        model.preferences.about.engineABI = 3
        model.preferences.about.memoryBudgetBytes = 12 * 1_073_741_824
        let text = await model.diagnosticText
        XCTAssertTrue(text.contains("Engine: Ready · version fixture-v1 · interface 3"), text)
        XCTAssertTrue(text.contains("Export memory limit: 12 GB"), text)
        XCTAssertTrue(text.contains("\nHDR preview: "), text)
        XCTAssertTrue(text.contains("\nMachine: macOS "), text)
        XCTAssertTrue(text.contains("\nModels: "), text)
    }
}
