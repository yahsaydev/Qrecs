import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Qrecs settings")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
        .scenePadding()
    }
}
