import XCTest
@testable import HyperDR

/// The canvas badge (parity G-14): "HDR" when the source is HDR or dual, or
/// the edited frame has gain, whatever weight the display currently applies.
@MainActor final class PhotoBadgeTests: XCTestCase {
    private func badge(_ mode: ViewMode = .edited, original: Bool = true,
                       domain: InputDomain? = .sceneReferred, gain: Double?) -> PhotoBadgeKind? {
        PhotoBadgeKind(viewMode: mode, originalAvailable: original, domain: domain, gainWeight: gain)
    }

    func testEditedFrameWithGainShowsHDRAtZeroWeight() {
        // An SDR display, or EDR headroom down to 1: the gain is there, unused.
        XCTAssertEqual(badge(gain: 0), .hdr)
    }

    func testEditedFrameWithGainShowsHDRAtPositiveWeight() {
        XCTAssertEqual(badge(gain: 0.6), .hdr)
    }

    func testEditedFrameWithoutGainShowsNoBadgeForSDRSources() {
        XCTAssertNil(badge(gain: nil))
        XCTAssertNil(badge(domain: .sdr, gain: nil))
        XCTAssertNil(badge(domain: nil, gain: nil))
    }

    func testHDRAndDualSourcesShowHDRWithoutGain() {
        XCTAssertEqual(badge(domain: .hdr, gain: nil), .hdr)
        XCTAssertEqual(badge(domain: .dual, gain: nil), .hdr)
    }

    func testOriginalShowsOriginalOnlyWhenAvailable() {
        XCTAssertEqual(badge(.original, domain: .hdr, gain: nil), .original)
        XCTAssertNil(badge(.original, original: false, domain: .hdr, gain: nil))
    }

    func testCompareShowsNoBadge() {
        XCTAssertNil(badge(.compare, domain: .hdr, gain: 1))
    }

    func testSDRDisplayFixtureKeepsTheBadge() {
        // The reviewer's case: editingSDRDisplay has gainWeight 0 on a RAW.
        let model = EditorModel.preview(.editingSDRDisplay)
        XCTAssertEqual(model.display.gainWeight, 0)
        XCTAssertEqual(model.document?.source?.domain, .sceneReferred)
        XCTAssertEqual(PhotoBadgeKind(viewMode: model.viewMode, originalAvailable: model.isAvailable(.original),
                                      domain: model.document?.source?.domain, gainWeight: model.display.gainWeight), .hdr)
    }
}
