import Foundation

/// The app's catalogue as `String`s, for the places a `Text` cannot be used:
/// a number format that carries a unit, a word interpolated into a sentence,
/// the names a model or a control gives at run time. `Text` follows the
/// environment's locale; this takes the locale explicitly so both agree.
nonisolated enum AppStrings {
    /// The entry for `key` in the best localization of the app for `locale`;
    /// the key itself when there is none.
    static func string(_ key: String, locale: Locale = .current, bundle: Bundle = .main) -> String {
        localizedBundle(for: locale, in: bundle).localizedString(forKey: key, value: key, table: nil)
    }

    /// `key`'s entry with `arguments` in place of its `%@`s.
    static func format(_ key: String, locale: Locale = .current, _ arguments: CVarArg...) -> String {
        String(format: string(key, locale: locale), locale: locale, arguments: arguments)
    }

    private static func localizedBundle(for locale: Locale, in bundle: Bundle) -> Bundle {
        let available = bundle.localizations.filter { $0 != "Base" }
        let best = Bundle.preferredLocalizations(from: available, forPreferences: [locale.identifier(.bcp47)]).first
        guard let best, let path = bundle.path(forResource: best, ofType: "lproj"),
              let localized = Bundle(path: path) else { return bundle }
        return localized
    }
}
