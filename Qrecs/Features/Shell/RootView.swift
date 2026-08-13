import SwiftUI

struct RootView: View {
    var body: some View {
        ContentUnavailableView(
            "Qrecs",
            systemImage: "waveform",
            description: Text("Your local recordings will appear here.")
        )
        .frame(minWidth: 720, minHeight: 480)
    }
}
