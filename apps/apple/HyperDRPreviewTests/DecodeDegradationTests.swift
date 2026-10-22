import XCTest
@testable import HyperDR

/// E-13: the user reads a sentence, not the engine's reason identifier.
final class DecodeDegradationTests: XCTestCase {
    private let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")

    func testEveryReasonTheEngineGivesMeansTheHDRDataCouldNotBeUsed() {
        for reason in ["ultrahdr_decode_failed_sdr_fallback", "gain_map_metadata_duplicate",
                       "avif_gain_map_pixels_unavailable_sdr_fallback",
                       "avif_gain_map_apply_failed_sdr_fallback: libavif said no",
                       "apple_legacy_gain_map_unusable_sdr_fallback: no auxiliary image"] {
            XCTAssertEqual(DecodeDegradation.key(for: reason), "warn.decode.hdrUnusable", reason)
        }
    }

    func testAnUnknownReasonGetsTheGeneralSentenceAndTheDetailIsNeverShown() {
        XCTAssertEqual(DecodeDegradation.key(for: "something_new"), "warn.decode.other")
        XCTAssertEqual(DecodeDegradation.key(for: ""), "warn.decode.other")
        // A known name after the colon does not make the reason known.
        XCTAssertEqual(DecodeDegradation.key(for: "something_new: ultrahdr_decode_failed_sdr_fallback"), "warn.decode.other")
        XCTAssertEqual(DecodeDegradation.key(for: "ultrahdr_decode_failed_sdr_fallback_extra"), "warn.decode.other")
    }

    func testSeveralReasonsGiveOneSentenceAndTheSpecificOneWins() {
        XCTAssertNil(DecodeDegradation.key(for: []))
        XCTAssertEqual(DecodeDegradation.key(for: ["gain_map_metadata_duplicate", "ultrahdr_decode_failed_sdr_fallback"]),
                       "warn.decode.hdrUnusable")
        XCTAssertEqual(DecodeDegradation.key(for: ["something_new", "ultrahdr_decode_failed_sdr_fallback"]), "warn.decode.hdrUnusable")
        XCTAssertEqual(DecodeDegradation.key(for: ["something_new", "other_new"]), "warn.decode.other")
    }

    func testTheSentencesAreWrittenInBothLanguagesWithoutIdentifiers() {
        XCTAssertEqual(AppStrings.string(DecodeDegradation.hdrUnusableKey, locale: en),
                       "The photo’s HDR data couldn’t be used, so it was treated as a standard photo.")
        XCTAssertEqual(AppStrings.string(DecodeDegradation.hdrUnusableKey, locale: zh), "这张照片的 HDR 数据无法使用，已按普通照片处理。")
        for key in [DecodeDegradation.hdrUnusableKey, DecodeDegradation.otherKey] {
            for locale in [en, zh] {
                let text = AppStrings.string(key, locale: locale)
                XCTAssertNotEqual(text, key)
                XCTAssertFalse(text.contains("_"), text)
            }
        }
    }
}
