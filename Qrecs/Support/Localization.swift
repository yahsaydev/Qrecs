import Foundation

extension AppPreferences {
    func text(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key),
            table: "Localizable",
            bundle: .main,
            locale: resolvedLanguage.locale
        )
    }
}

extension AmbientSound {
    func displayName(language: ResolvedAppLanguage) -> String {
        language == .russian ? nameRU : nameEN
    }
}
