import Foundation
import HyperDRKit
import XCTest

/// The catalogue keys that are built from a prefix and a name at run time,
/// which `scripts/check_apple_i18n.py` cannot see in the Swift and so
/// exempts by prefix (`ctrl.`, `choice.`, `field.`, `enc.`, `export.stage.`,
/// `export.unavailable.`). This is what keeps them
/// honest: every key a control or an option will ask for is in the
/// catalogue in both languages, and every key under those prefixes belongs
/// to a control or an option that exists.
final class LocalizationCoverageTests: XCTestCase {
    /// The capture fields the engine can report as missing from a photo, as
    /// the AI fallback names them (`field.<name>`).
    private static let captureFields = ["iso", "exposure_seconds", "f_number", "exposure_bias_ev",
                                        "focal_length_mm", "focal_length_35mm"]

    /// The phases an export reports (`export.stage.<name>`; "processColor"
    /// is the colour-only wording of "process") and the reasons a format is
    /// unavailable (`export.unavailable.short|full.<name>`).
    private static let exportStages = ["preparing", "decode", "process", "processColor", "encode", "verify"]
    private static let unavailableReasons = ["hevc", "main10", "probe", "generic"]

    /// A key's text by language, as the app bundle ships it.
    private typealias Entry = [String: String]

    /// The compiled catalogue in the app that hosts the tests. Reading the
    /// source `.xcstrings` through `#filePath` instead opens a file under
    /// ~/Desktop from the sandboxed host, whose first read waits for the
    /// system's folder-access check (2.4 s alone, over a minute on a busy
    /// machine) for no gain: the bundle holds exactly what the app ships.
    ///
    /// The compiled strings keep no translation state, so this test cannot see
    /// a string left at `needs_review`; `scripts/check_apple_i18n.py` rejects
    /// every unit that is not `translated`.
    private func catalogue() throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        for locale in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                                      forLocalization: locale), "no \(locale) strings in the app")
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
            for (key, text) in table { result[key, default: [:]][locale] = text }
        }
        return result
    }

    private func value(_ entry: Entry, _ locale: String) -> String? { entry[locale] }

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

    func testEveryExportFormatHasItsCardText() throws {
        let catalogue = try catalogue()
        let formats = try XCTUnwrap(EditChoices.byKey["encoding"]).options.map(\.id)
        XCTAssertEqual(Set(formats), ["adaptive", "iso-gainmap-jpeg", "pq", "hlg", "avif-pq", "avif-hlg", "sdr-jpeg", "sdr-tiff"])
        assertTranslated(formats.flatMap { ["enc.\($0).label", "enc.\($0).hint", "enc.\($0).detail"] }, in: catalogue)
        assertTranslated(Self.exportStages.map { "export.stage.\($0)" }, in: catalogue)
        assertTranslated(Self.unavailableReasons.flatMap { ["export.unavailable.short.\($0)", "export.unavailable.full.\($0) %@"] },
                         in: catalogue)
        // The option's own name and the card's are one word.
        for id in formats {
            for locale in ["en", "zh-Hans"] {
                XCTAssertEqual(value(try XCTUnwrap(catalogue["choice.encoding.\(id)"]), locale),
                               value(try XCTUnwrap(catalogue["enc.\(id).label"]), locale), "[\(locale)] \(id)")
            }
        }
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
            case "enc":
                // enc.<id>.label | .hint | .detail (ids contain dashes, not dots)
                guard parts.count == 3, EditChoices.byKey["encoding"]?.options.contains(where: { $0.id == parts[1] }) == true,
                      ["label", "hint", "detail"].contains(parts[2]) else {
                    orphans.append(key)
                    continue
                }
            case "export" where parts.count > 1 && parts[1] == "stage":
                if parts.count != 3 || !Self.exportStages.contains(parts[2]) { orphans.append(key) }
            case "export" where parts.count > 1 && parts[1] == "unavailable":
                // export.unavailable.short.<reason> | export.unavailable.full.<reason> %@
                let reason = parts.last?.replacingOccurrences(of: " %@", with: "") ?? ""
                if parts.count != 4 || !["short", "full"].contains(parts[2]) || !Self.unavailableReasons.contains(reason) {
                    orphans.append(key)
                }
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
