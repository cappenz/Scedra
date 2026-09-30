import Foundation

/// UI language follows the **phone**. Never an in-app picker, never a leftover override.
enum ScedraLocale {
    static let overrideKey = "scedra.language"
    static let supportedLanguageCodes = ["en", "fr", "es", "de"]

    /// Drop leftover picker keys only. `AppleLanguages` belongs to iOS — deleting it
    /// on every launch fights Settings → Scedra → Language and can empty the catalog
    /// after a system language change.
    static func followPhoneLanguage(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: overrideKey)
        defaults.removeObject(forKey: "scedra.locale")
    }

    /// Phone locale after quit+relaunch. Not a reconstructed `Locale(identifier: "de")`.
    static var phone: Locale { .autoupdatingCurrent }

    static var phoneLanguageCode: String {
        supportedLanguage(from: phone)
    }

    static func supportedLanguage(from locale: Locale) -> String {
        var preferred: [String] = [locale.identifier]
        if let code = locale.language.languageCode?.identifier {
            preferred.insert(code, at: 0)
        }
        return supportedLanguage(fromPreferred: preferred)
    }

    static func supportedLanguage(fromPreferred preferred: [String]) -> String {
        for identifier in preferred {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier,
               supportedLanguageCodes.contains(code) {
                return code
            }
        }
        return "en"
    }

    /// Compiled catalog for one supported language (`de.lproj`, `fr.lproj`, …).
    static func stringsBundle(for locale: Locale) -> Bundle {
        stringsBundle(forLanguage: supportedLanguage(from: locale))
    }

    static func stringsBundle(forLanguage code: String) -> Bundle {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if code != "en",
           let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }
}

/// Looks up chrome in the phone language’s `lproj`.
/// `String(localized:locale:)` alone does **not** switch catalogs — after a phone
/// language change that left `Bundle.main` stale, it can return English or empty.
func ScedraString(_ value: String.LocalizationValue, locale: Locale = .autoupdatingCurrent) -> String {
    let bundle = ScedraLocale.stringsBundle(for: locale)
    let localized = String(localized: value, table: nil, bundle: bundle, locale: locale)
    if localized.isEmpty {
        let english = ScedraLocale.stringsBundle(forLanguage: "en")
        return String(localized: value, table: nil, bundle: english, locale: Locale(identifier: "en"))
    }
    return localized
}

extension Date {
    /// Display clocks follow `Locale.current` at format time — never a captured German locale.
    func scedraDisplay(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(.current))
    }

    func scedraHourLabel() -> String {
        formatted(Date.FormatStyle.dateTime.hour().locale(.current))
    }
}
