import Foundation

/// The package's own strings as `String`s, for the places a `Text` cannot be
/// used: a text field's contents and VoiceOver values. Views use
/// `Text(_:bundle: .module)`, which follows the environment's locale; this
/// takes the locale explicitly so a field shows the same language.
enum DesignStrings {
    /// The `key` in the best localization of the package for `locale`
    /// (English when none matches).
    static func string(_ key: String, bundle: Bundle = .module, locale: Locale = .current) -> String {
        Self.bundle(for: locale, in: bundle).localizedString(forKey: key, value: key, table: nil)
    }

    /// Whether `text` is the word "Auto" in any language the package ships,
    /// in any case.
    static func isAutomaticWord(_ text: String) -> Bool {
        Bundle.module.localizations.contains { language in
            guard language != "Base", let path = Bundle.module.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return false }
            return bundle.localizedString(forKey: "design.slider.auto", value: nil, table: nil)
                .caseInsensitiveCompare(text) == .orderedSame
        }
    }

    private static func bundle(for locale: Locale, in bundle: Bundle) -> Bundle {
        let available = bundle.localizations.filter { $0 != "Base" }
        let best = Bundle.preferredLocalizations(from: available, forPreferences: [locale.identifier(.bcp47)]).first
        guard let best, let path = bundle.path(forResource: best, ofType: "lproj"),
              let localized = Bundle(path: path) else { return bundle }
        return localized
    }
}
