import SwiftUI

@main
@MainActor
struct QrecsApp: App {
    @StateObject private var preferences: AppPreferences
    @StateObject private var container: AppContainer

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        let defaults: UserDefaults
        if isUITesting {
            defaults = UserDefaults(suiteName: "Qrecs.UITests.\(UUID().uuidString)")!
        } else {
            defaults = .standard
        }
        let preferences = AppPreferences(defaults: defaults)
        if let argument = arguments.first(where: { $0.hasPrefix("--language=") }) {
            preferences.language = argument.hasSuffix("=ru") ? .russian : .english
        }
        if let argument = arguments.first(where: { $0.hasPrefix("--theme=") }) {
            preferences.theme = argument.hasSuffix("=dark") ? .dark : .light
        }
        _preferences = StateObject(wrappedValue: preferences)
        _container = StateObject(wrappedValue: AppContainer(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup(RootConfiguration.standard.appName) {
            RootView(container: container, preferences: preferences)
                .preferredColorScheme(preferences.theme.colorScheme)
        }
        .defaultSize(width: 1_080, height: 720)
        .commands { PlaybackCommands(container: container) }

        Settings {
            SettingsView(container: container, preferences: preferences)
                .preferredColorScheme(preferences.theme.colorScheme)
        }
    }
}
