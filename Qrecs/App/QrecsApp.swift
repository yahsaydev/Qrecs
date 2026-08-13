import SwiftUI

@main
struct QrecsApp: App {
    var body: some Scene {
        WindowGroup(RootConfiguration.standard.appName) {
            RootView()
        }

        Settings {
            SettingsView()
        }
    }
}
