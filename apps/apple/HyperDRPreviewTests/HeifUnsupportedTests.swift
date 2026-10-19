import XCTest
import HyperDREngine
@testable import HyperDR

/// The HEIF reader names the feature it cannot read; the user reads a sentence
/// about it, never the identifier or the engine's wording.
@MainActor final class HeifUnsupportedTests: XCTestCase {
    private let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")

    private func error(feature: String?, container: String = "heif", message: String = "engine words") -> UserFacingError {
        var fields: [String: JSONValue] = ["container": .string(container)]
        if let feature { fields["feature"] = .string(feature) }
        return UserFacingError(HyperDRError(code: "unsupported_format", message: message, detail: .object(fields)))
    }

    func testEveryFeatureTheReaderReportsGetsItsOwnSentence() {
        XCTAssertEqual(ErrorText.heifFeatures.count, 15)
        var seen = Set<String>()
        for feature in ErrorText.heifFeatures {
            let mapped = error(feature: feature)
            XCTAssertEqual(mapped.code, "unsupported_format")
            XCTAssertEqual(mapped.variant, "heif_" + feature)
            XCTAssertNil(mapped.detail, "the engine’s wording is not shown for \(feature)")
            let text = ErrorText(mapped)
            XCTAssertNil(text.detail)
            for locale in [en, zh] {
                let body = text.body(locale: locale)
                // "codec" and "handler" are also ordinary words; the underscored identifiers are not.
                if feature.contains("_") { XCTAssertFalse(body.contains(feature), "the identifier \(feature) is not shown") }
                XCTAssertFalse(body.contains("err.server"), body)
                XCTAssertFalse(body.contains("engine words"), body)
                XCTAssertNotEqual(text.title(locale: locale), ErrorText(UserFacingError(code: "unsupported_format")).title(locale: locale),
                                  "HEIF has its own title")
            }
            XCTAssertTrue(seen.insert(text.body(locale: en)).inserted, "\(feature) has a sentence of its own")
            // Chinese is a translation, not the English sentence.
            XCTAssertNotEqual(text.body(locale: zh), text.body(locale: en))
        }
    }

    func testTheSentencesNameWhatIsWrong() {
        XCTAssertTrue(ErrorText(error(feature: "image_sequence")).body(locale: en).contains("image sequence"))
        XCTAssertTrue(ErrorText(error(feature: "hevc_444")).body(locale: en).contains("4:4:4"))
        XCTAssertTrue(ErrorText(error(feature: "hevc_422")).body(locale: zh).contains("4:2:2"))
        XCTAssertTrue(ErrorText(error(feature: "protected_item")).body(locale: zh).contains("保护"))
        XCTAssertEqual(ErrorText(error(feature: "hevc_12bit")).body(locale: en),
                       "This photo is 12-bit, which HyperDR doesn’t support. It reads 8-bit and 10-bit photos.")
    }

    func testAnUnknownFeatureFallsBackToAGeneralHEIFSentenceAndKeepsTheDetail() {
        let mapped = error(feature: "brand_new_feature")
        XCTAssertEqual(mapped.variant, "heif_unknown")
        XCTAssertEqual(mapped.detail, "engine words", "the engine’s wording stays for a bug report")
        let text = ErrorText(mapped)
        XCTAssertFalse(text.body(locale: en).contains("brand_new_feature"))
        XCTAssertTrue(text.body(locale: en).hasPrefix("HyperDR can’t read this HEIF photo"))
        XCTAssertTrue(text.body(locale: zh).hasPrefix("HyperDR 无法读取这张 HEIF 照片"))
    }

    func testOtherUnsupportedFormatsKeepTheOrdinaryText() {
        for mapped in [error(feature: nil), error(feature: "image_sequence", container: "jpeg"),
                       UserFacingError(HyperDRError(code: "unsupported_format", message: "no extension"))] {
            XCTAssertNil(mapped.variant)
            XCTAssertEqual(ErrorText(mapped).body(locale: en).prefix(34), "Choose a RAW, JPEG, PNG, TIFF, HEI")
        }
    }

    func testTheFeatureListMatchesTheOnesTheEngineSources() throws {
        // Every feature string the reader and decoder throw, found in the sources, has a sentence.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = ["modules/container/src/heif_reader.cpp", "modules/container/src/hvcc.cpp",
                     "modules/codec/src/hevc/vt_decoder.cpp", "modules/codec/src/hevc/yuv_to_rgb.cpp"]
        let pattern = try NSRegularExpression(pattern: #"HeifReadError\([^;]*?,\s*(?:[^;"]*\?\s*)?"([a-z0-9_]+)""#,
                                              options: [.dotMatchesLineSeparators])
        var found = Set<String>()
        for file in files {
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else {
                throw XCTSkip("engine sources are not next to the tests")
            }
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.isSubset(of: Set(ErrorText.heifFeatures)), "unmapped: \(found.subtracting(ErrorText.heifFeatures))")
    }
}
