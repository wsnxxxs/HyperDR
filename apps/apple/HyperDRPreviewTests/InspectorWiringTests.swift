import SwiftUI
import XCTest
import HyperDRDesign
@testable import HyperDR

/// The glue between the editor model and the design components: how a
/// control becomes a `ParameterSpec`, what the AI part of the inspector says
/// in each state, how the scope data is handed over.
@MainActor final class InspectorWiringTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/fixtures/a.jpg")

    private func opened(domain: InputDomain = .sdr, tagged: Bool = false) async -> EditorModel {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(1))
        services.preview = EditorPreview(pixelSize: PixelSize(width: 6000, height: 4000),
            source: SourceSummary(domain: domain, colorName: "sRGB", degradationReasons: [],
                                  colorSource: tagged ? "icc" : "assumed"), hasGain: true, unadjusted: nil)
        let model = EditorModel(services: services)
        model.open([url])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        return model
    }

    // MARK: Control to spec

    func testEveryControlBecomesAValidSpecInBothLanguages() async {
        let model = await opened()
        for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans")] {
            for control in model.controls {
                let spec = ParameterSpecFactory.spec(for: control, locale: locale)
                XCTAssertEqual(spec.step, control.spec.step, control.key)
                XCTAssertEqual(spec.automatic != nil, control.spec.allowsAuto, control.key)
                // The default, whatever it is (Auto is -1), reads without crashing.
                XCTAssertFalse(spec.formatted(control.defaultValue, locale: locale).isEmpty, control.key)
            }
        }
    }

    func testSignedControlsFillFromZeroAndOthersFromTheLowerBound() async {
        let model = await opened(domain: .hdr)
        let brightness = ParameterSpecFactory.spec(for: model.control("brightness"), locale: Locale(identifier: "en"))
        XCTAssertEqual(brightness.origin, 0)
        XCTAssertTrue(brightness.isCentred, "an HDR source can go below 0, so the fill starts mid-track")
        let strength = ParameterSpecFactory.spec(for: model.control("hdrStrength"), locale: Locale(identifier: "en"))
        XCTAssertEqual(strength.origin, strength.range.lowerBound)
    }

    func testAutoControlsKeepAutoBelowTheRange() async {
        let model = await opened()
        model.setAIMode(.optimized)
        await eventually(timeout: .seconds(3)) { model.ai.availability != .available && !model.ai.isComputing }
        let control = model.control("aiHdrRange")
        let spec = ParameterSpecFactory.spec(for: control, locale: Locale(identifier: "en"))
        XCTAssertGreaterThanOrEqual(spec.range.lowerBound, 0)
        XCTAssertTrue(spec.isAutomatic(-1))
        XCTAssertEqual(spec.formatted(-1, locale: Locale(identifier: "zh-Hans")), "自动")
        XCTAssertEqual(spec.formatted(-1, locale: Locale(identifier: "en")), "Auto")
    }

    func testStopsReadoutIsWrittenInTheRequestedLanguage() async {
        let model = await opened()
        let en = ParameterSpecFactory.spec(for: model.control("hdrRange"), locale: Locale(identifier: "en"))
        let zh = ParameterSpecFactory.spec(for: model.control("hdrRange"), locale: Locale(identifier: "zh-Hans"))
        XCTAssertEqual(en.formatted(2.5, locale: Locale(identifier: "en")), "2.5 stops")
        XCTAssertEqual(zh.formatted(2.5, locale: Locale(identifier: "zh-Hans")), "2.5 档")
    }

    func testTheFormatCeilingIsReportedOnlyWhenItLowersTheRange() async {
        let model = await opened()
        model.setWorkflow(.hdr)
        let control = model.control("hdrRange")
        // The control's own range goes to 4; each format may hold it lower.
        XCTAssertEqual(control.spec.range.upperBound, 4)
        model.selectEncoding("adaptive")
        let adaptive = EditBaseline.maxRange(for: "adaptive")
        XCTAssertLessThan(adaptive, 4)
        XCTAssertEqual(ParameterSpecFactory.ceiling(of: control), adaptive)
        model.selectEncoding("pq")
        XCTAssertEqual(EditBaseline.maxRange(for: "pq"), 4)
        XCTAssertNil(ParameterSpecFactory.ceiling(of: control))
    }

    // MARK: AI panel

    private func panel(domain: InputDomain? = .sdr, mode: AIMode = .manual,
                       availability: AIAvailability = .available, computing: Bool = false,
                       missing: [String] = [], notice: EditorNotice? = nil) -> AIPanelState {
        AIPanelState.make(domain: domain, mode: mode, availability: availability, isComputing: computing,
                          fallbackMissingFields: missing, notice: notice)
    }

    func testManualWithAIAvailableShowsTheHintAndAllowsAI() {
        let state = panel()
        XCTAssertTrue(state.showsModeSwitch)
        XCTAssertTrue(state.isAIEnabled)
        XCTAssertEqual(state.lines, [.manualNote])
        XCTAssertEqual(panel(availability: .cached).lines, [.cached])
    }

    func testComputingSelectsAIDisablesTheSwitchAndSaysSo() {
        let state = panel(mode: .optimized, availability: .available, computing: true)
        XCTAssertTrue(state.isAISelected)
        XCTAssertFalse(state.isAIEnabled)
        XCTAssertEqual(state.lines, [.computing])
        XCTAssertEqual(AIPanelState.Line.computing.style, .progress)
    }

    func testAppliedShowsTheModelAndTheFallbackWarning() {
        let applied = panel(mode: .optimized, availability: .applied(modelName: "model.research-exif-v1"))
        XCTAssertEqual(applied.lines, [.applied(modelNameKey: "model.research-exif-v1")])
        let fallback = panel(mode: .optimized, availability: .applied(modelName: "model.research-exif-v1"),
                             missing: ["f_number", "focal_length_mm"])
        XCTAssertEqual(fallback.lines.last, .fallback(fields: ["f_number", "focal_length_mm"]))
        XCTAssertEqual(fallback.lines.last?.style, .warning)
        XCTAssertTrue(fallback.isAIEnabled, "AI can be switched off while it is applied")
    }

    func testFailureOutranksUnavailableAndRestsTheAISegment() {
        let state = panel(availability: .unavailable(reasonKey: "ai.unavailable.failed"),
                          notice: .aiFailed(reasonKey: "ai.unavailable.failed"))
        XCTAssertEqual(state.lines, [.failed(reasonKey: "ai.unavailable.failed")])
        XCTAssertFalse(state.isAIEnabled)
        // After the notice is cleared the plain reason remains.
        XCTAssertEqual(panel(availability: .unavailable(reasonKey: "ai.unavailable.failed")).lines,
                       [.unavailable(reasonKey: "ai.unavailable.failed")])
    }

    func testHDRSourcesHaveNoSwitchOnlyTheirExplanation() {
        for domain in [InputDomain.hdr, .dual] {
            let state = panel(domain: domain, availability: .unavailable(reasonKey: "ai.unavailable.hdrSource"))
            XCTAssertFalse(state.showsModeSwitch)
            XCTAssertEqual(state.lines, [.hdrSource])
        }
    }

    func testColorOnlyRestsAIWithItsReason() {
        let state = panel(availability: .unavailable(reasonKey: "ai.unavailable.colorOnly"))
        XCTAssertFalse(state.isAIEnabled)
        XCTAssertEqual(state.lines, [.unavailable(reasonKey: "ai.unavailable.colorOnly")])
    }

    func testTheMissingFieldsReadAsAListInEachLanguage() {
        XCTAssertEqual(AdjustmentSection.fieldList(["f_number", "focal_length_mm"], locale: Locale(identifier: "en")),
                       "aperture and focal length")
        XCTAssertEqual(AdjustmentSection.fieldList(["f_number", "focal_length_mm"], locale: Locale(identifier: "zh-Hans")),
                       "光圈和焦距")
    }

    func testFailureNoticeClearsButResetDoneDoesNot() async {
        let model = await opened()
        model.notice = .resetDone
        model.clearAIFailureNotice()
        XCTAssertEqual(model.notice, .resetDone)
        model.notice = .aiFailed(reasonKey: "ai.unavailable.failed")
        model.clearAIFailureNotice()
        XCTAssertNil(model.notice)
    }

    // MARK: Scopes

    func testScopeContentFollowsTheMeasurementAndThePhase() async {
        let model = await opened()
        XCTAssertEqual(ScopeSection.content(scopes: model.scopes, phase: .ready), .measuring)
        XCTAssertEqual(ScopeSection.content(scopes: model.scopes,
                                            phase: .failed(UserFacingError(code: "x"))), .unavailable)
        let bins = HistogramData.bins
        let flat = [UInt32](repeating: 1, count: bins)
        let histogram = HistogramData(total: bins, luma: flat, red: flat, green: flat, blue: flat)
        let waveform = WaveformData(columns: 2, counts: [UInt32](repeating: 3, count: 2 * WaveformData.rows))
        model.scopes.update(original: .some(histogram), current: .some(histogram), waveform: .some(waveform))
        guard case .data(let data) = ScopeSection.content(scopes: model.scopes, phase: .ready) else {
            return XCTFail("measured scopes are data")
        }
        XCTAssertEqual(data.current?.luma, flat)
        XCTAssertEqual(data.original?.red, flat)
        XCTAssertEqual(data.waveform?.columns, 2)
        XCTAssertEqual(data.waveform?.rows, WaveformData.rows)
        XCTAssertEqual(data.waveform?.counts.count, 2 * WaveformData.rows)
    }

    // MARK: Held arrow keys (batch 4 §2.4)

    /// What the slider does with a held arrow, replayed through the row's
    /// own binding and bracket: down + repeats are one undo step.
    func testAHeldArrowIsOneUndoStep() async {
        let model = await opened()
        let initial = model.control("brightness").value
        let binding = ControlSlider.binding(model: model, key: "brightness")
        let editing = ControlSlider.editing(model: model, key: "brightness")
        let spec = ParameterSpecFactory.spec(for: model.control("brightness"), locale: Locale(identifier: "en"))
        // The slider's own decision, as the track and the readout make it
        // (ArrowKeyEditing, tested in the design package): a session opens
        // at the first key-down and closes at the key-up.
        editing(true)
        for _ in 0..<3 { binding.wrappedValue = spec.stepped(binding.wrappedValue, by: 1) }
        editing(false)
        XCTAssertEqual(model.control("brightness").value, initial + 3 * spec.step, accuracy: 1e-6)
        model.undo()
        XCTAssertEqual(model.control("brightness").value, initial, accuracy: 1e-6, "one undo takes back the whole hold")
        XCTAssertFalse(model.canUndo)
        model.closeDocument()
    }

    func testTwoSeparatePressesAreTwoUndoSteps() async {
        let model = await opened()
        let initial = model.control("brightness").value
        let binding = ControlSlider.binding(model: model, key: "brightness")
        let editing = ControlSlider.editing(model: model, key: "brightness")
        let spec = ParameterSpecFactory.spec(for: model.control("brightness"), locale: Locale(identifier: "en"))
        for _ in 0..<2 {
            editing(true)
            binding.wrappedValue = spec.stepped(binding.wrappedValue, by: 1)
            editing(false)
        }
        model.undo()
        XCTAssertEqual(model.control("brightness").value, initial + spec.step, accuracy: 1e-6)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.control("brightness").value, initial, accuracy: 1e-6)
        XCTAssertFalse(model.canUndo)
        model.closeDocument()
    }
}
