import Foundation
import HyperDRKit
import XCTest

/// The catalogue keys that are built from a prefix and a name at run time,
/// which `scripts/check_apple_i18n.py` cannot see in the Swift and so
/// exempts by prefix (`ctrl.`, `choice.`, `field.`). This is what keeps them
/// honest: every key a control or an option will ask for is in the
/// catalogue in both languages, and every key under those prefixes belongs
/// to a control or an option that exists.
final class LocalizationCoverageTests: XCTestCase {
    /// The capture fields the engine can report as missing from a photo, as
    /// the AI fallback names them (`field.<name>`).
    private static let captureFields = ["iso", "exposure_seconds", "f_number", "exposure_bias_ev",
                                        "focal_length_mm", "focal_length_35mm"]

    private typealias Entry = [String: Any]

    private func catalogue() throws -> [String: Entry] {
        // HyperDRPreviewTests/ is next to HyperDR/ in the source tree.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HyperDR/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(object?["strings"] as? [String: Entry])
    }

    private func value(_ entry: Entry, _ locale: String) -> String? {
        let localizations = entry["localizations"] as? [String: Entry]
        let unit = localizations?[locale]?["stringUnit"] as? [String: String]
        guard unit?["state"] == "translated" else { return nil }
        return unit?["value"]
    }

    private func assertTranslated(_ keys: [String], in catalogue: [String: Entry], file: StaticString = #filePath,
                                  line: UInt = #line) {
        for key in keys {
            guard let entry = catalogue[key] else {
                XCTFail("missing from the catalogue: \(key)", file: file, line: line)
                continue
            }
            for locale in ["en", "zh-Hans"] {
                XCTAssertFalse(value(entry, locale)?.isEmpty ?? true, "[\(locale)] \(key)", file: file, line: line)
            }
        }
    }

    func testEveryControlAndChoiceKeyIsTranslated() throws {
        let catalogue = try catalogue()
        let controlKeys = EditControls.all.flatMap { [$0.labelKey] + [$0.helpKey].compactMap { $0 } }
        let choiceKeys = EditChoices.all.flatMap { $0.options.map(\.labelKey) }
        XCTAssertEqual(controlKeys.count, EditControls.all.count * 2, "every control has a label and a help")
        XCTAssertFalse(choiceKeys.isEmpty)
        assertTranslated(controlKeys, in: catalogue)
        assertTranslated(choiceKeys, in: catalogue)
        assertTranslated(Self.captureFields.map { "field.\($0)" }, in: catalogue)
    }

    func testNoKeyUnderADynamicPrefixIsAnOrphan() throws {
        let catalogue = try catalogue()
        var orphans: [String] = []
        for key in catalogue.keys.sorted() {
            let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            switch parts.first {
            case "ctrl":
                // ctrl.<key>.label | ctrl.<key>.help
                guard parts.count == 3, let spec = EditControls.byKey[parts[1]],
                      parts[2] == "label" || (parts[2] == "help" && spec.helpKey != nil) else {
                    orphans.append(key)
                    continue
                }
            case "choice":
                // choice.<key>.<id>
                guard parts.count == 3, EditChoices.byKey[parts[1]]?.options.contains(where: { $0.id == parts[2] }) == true else {
                    orphans.append(key)
                    continue
                }
            case "field":
                if parts.count != 2 || !Self.captureFields.contains(parts[1]) { orphans.append(key) }
            default:
                break
            }
        }
        XCTAssertEqual(orphans, [], "keys with no control, option or field behind them")
    }

    func testTheFieldsAreExactlyTheCaptureFields() throws {
        let fields = try catalogue().keys.filter { $0.hasPrefix("field.") }.map { String($0.dropFirst("field.".count)) }
        XCTAssertEqual(Set(fields), Set(Self.captureFields))
    }
}
