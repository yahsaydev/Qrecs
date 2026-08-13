import SwiftUI

struct PlaybackCommands: Commands {
    @ObservedObject var container: AppContainer

    var body: some Commands {
        CommandMenu(container.preferences.text("Playback")) {
            Button(container.preferences.text("Play")) {
                container.store?.playPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(container.store?.playerState.currentTrack == nil)

            Divider()

            Button(container.preferences.text("Previous")) {
                container.store?.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .disabled(container.store?.playerState.canGoPrevious != true)

            Button(container.preferences.text("Next")) {
                container.store?.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .disabled(container.store?.playerState.canGoNext != true)
        }
    }
}
