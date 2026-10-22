import Foundation
import Testing
@testable import HyperDRDesign

/// Every export notice and reason has its words in both languages, with
/// its values filled in.
@Test func everyExportPhraseIsTranslatedWithItsValues() {
    let phrases: [ExportReasonPhrase] = [
        .ceiling(stops: "+3", byFormat: false), .ceiling(stops: "+3", byFormat: true),
        .socialAspect, .sdrVersion, .alphaOnBlack, .memory(needed: "3.1 GB", available: "900 MB"),
        .photosNotVerified, .photosPermission, .photosFileSource, .photosFramed, .photosAddOnly,
        .photosLibraryAccess, .hevcUnavailable, .hevcMain10Unavailable, .hevcProbeFailed, .hdrOff,
        .unsupportedPair, .notYetAvailable, .useLongEdge(4096),
    ]
    for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans")] {
        var seen = Set<String>()
        for phrase in phrases {
            let text = phrase.text(locale: locale)
            #expect(!text.hasPrefix("export.reason."), "\(phrase) \(locale.identifier)")
            #expect(!text.contains("%@"), "\(phrase) \(locale.identifier)")
            #expect(seen.insert(text).inserted, "\(phrase) repeats another phrase")
        }
    }
    #expect(ExportReasonPhrase.memory(needed: "3.1 GB", available: "900 MB").text(locale: Locale(identifier: "en"))
        .contains("3.1 GB"))
    #expect(ExportReasonPhrase.useLongEdge(4096).text(locale: Locale(identifier: "zh-Hans")) == "改为长边 4096 px")
    #expect(ExportReasonPhrase.ceiling(stops: "+3", byFormat: false).text(locale: Locale(identifier: "en")).contains("+3 EV"))
}
