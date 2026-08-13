import Combine
import Foundation

enum ResolvedAppLanguage: String, Equatable, Sendable {
    case russian
    case english

    var locale: Locale {
        Locale(identifier: self == .russian ? "ru" : "en")
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case russian
    case english

    var id: String { rawValue }

    func resolve(preferredLanguages: [String]) -> ResolvedAppLanguage {
        switch self {
        case .russian:
            return .russian
        case .english:
            return .english
        case .system:
            guard let primary = preferredLanguages.first else { return .english }
            return Locale(identifier: primary).language.languageCode == .russian
                ? .russian
                : .english
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

enum ReciterSort: String, CaseIterable, Identifiable, Sendable {
    case name
    var id: String { rawValue }
}

enum TrackSort: String, CaseIterable, Identifiable, Sendable {
    case number
    case name
    case status

    var id: String { rawValue }
}

enum SortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending
    case descending

    var id: String { rawValue }
}

@MainActor
final class AppPreferences: ObservableObject {
    enum Key {
        static let language = "settings.language"
        static let theme = "settings.theme"
        static let manualOffline = "settings.manualOffline"
        static let quranVolume = "settings.quranVolume"
        static let ambientMasterVolume = "settings.ambient.masterVolume"

        static func ambientEnabled(_ sound: AmbientSound) -> String {
            "settings.ambient.\(sound.rawValue).enabled"
        }

        static func ambientVolume(_ sound: AmbientSound) -> String {
            "settings.ambient.\(sound.rawValue).volume"
        }
    }

    private let defaults: UserDefaults
    private let preferredLanguages: [String]

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    @Published var manualOffline: Bool {
        didSet { defaults.set(manualOffline, forKey: Key.manualOffline) }
    }

    @Published var quranVolume: Double {
        didSet {
            let normalized = Self.clamp(quranVolume)
            guard normalized == quranVolume else {
                quranVolume = normalized
                return
            }
            defaults.set(quranVolume, forKey: Key.quranVolume)
        }
    }

    @Published var ambientMasterVolume: Double {
        didSet {
            let normalized = Self.clamp(ambientMasterVolume)
            guard normalized == ambientMasterVolume else {
                ambientMasterVolume = normalized
                return
            }
            defaults.set(ambientMasterVolume, forKey: Key.ambientMasterVolume)
        }
    }

    @Published private var ambientEnabledValues: [AmbientSound: Bool]
    @Published private var ambientVolumeValues: [AmbientSound: Double]

    init(
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        language = AppLanguage(
            rawValue: defaults.string(forKey: Key.language) ?? ""
        ) ?? .system
        theme = AppTheme(
            rawValue: defaults.string(forKey: Key.theme) ?? ""
        ) ?? .system
        manualOffline = defaults.bool(forKey: Key.manualOffline)
        quranVolume = Self.persistedVolume(
            defaults: defaults,
            key: Key.quranVolume,
            fallback: 1
        )
        ambientMasterVolume = Self.persistedVolume(
            defaults: defaults,
            key: Key.ambientMasterVolume,
            fallback: 0.5
        )
        ambientEnabledValues = Dictionary(
            uniqueKeysWithValues: AmbientSound.allCases.map {
                ($0, defaults.bool(forKey: Key.ambientEnabled($0)))
            }
        )
        ambientVolumeValues = Dictionary(
            uniqueKeysWithValues: AmbientSound.allCases.map {
                ($0, Self.persistedVolume(
                    defaults: defaults,
                    key: Key.ambientVolume($0),
                    fallback: 0.5
                ))
            }
        )
    }

    var resolvedLanguage: ResolvedAppLanguage {
        language.resolve(preferredLanguages: preferredLanguages)
    }

    func ambientEnabled(_ sound: AmbientSound) -> Bool {
        ambientEnabledValues[sound] ?? false
    }

    func setAmbientEnabled(_ enabled: Bool, for sound: AmbientSound) {
        ambientEnabledValues[sound] = enabled
        defaults.set(enabled, forKey: Key.ambientEnabled(sound))
    }

    func ambientVolume(_ sound: AmbientSound) -> Double {
        ambientVolumeValues[sound] ?? 0.5
    }

    func setAmbientVolume(_ volume: Double, for sound: AmbientSound) {
        let volume = Self.clamp(volume)
        ambientVolumeValues[sound] = volume
        defaults.set(volume, forKey: Key.ambientVolume(sound))
    }

    private static func persistedVolume(
        defaults: UserDefaults,
        key: String,
        fallback: Double
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.double(forKey: key)
        return value.isFinite && (0...1).contains(value) ? value : fallback
    }

    private static func clamp(_ volume: Double) -> Double {
        min(max(volume.isFinite ? volume : 0, 0), 1)
    }
}
