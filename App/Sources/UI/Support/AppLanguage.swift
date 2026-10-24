import Foundation

/// The language the app resolved at launch: Ukrainian on a phone set to Ukrainian,
/// English otherwise (`CFBundleLocalizations` / the catalogs decide). Pack titles,
/// the spoken GPS phrases and their voice follow this, not the raw
/// `Locale.preferredLanguages` (["ru", "uk"] resolves the UI to Ukrainian).
enum AppLanguage {
    /// The bundle's resolved localizations, best first (`["uk"]` or `["en"]`).
    static var preferredLanguages: [String] { Bundle.main.preferredLocalizations }

    /// "uk" or "en".
    static var code: String { preferredLanguages.first ?? "en" }

    static var isUkrainian: Bool { code.hasPrefix("uk") }

    /// BCP 47 tag of the speech voice for `appLanguage`. Ukrainian: `uk-UA`.
    /// English: the phone's own voice language when it is English (en-GB stays
    /// en-GB), else `en-US`.
    static func voiceLanguage(appLanguage: String, systemVoiceLanguage: String) -> String {
        if appLanguage.hasPrefix("uk") { return "uk-UA" }
        return systemVoiceLanguage.hasPrefix("en") ? systemVoiceLanguage : "en-US"
    }
}
