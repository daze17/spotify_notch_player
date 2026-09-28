import AppKit
import SwiftUI

@main
struct NotchPlayerApp: App {
    // SwiftUI's App lifecycle has no hook for custom windows, so we bridge to a
    // classic AppDelegate and build the panel ourselves in AppKit.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // An App needs at least one scene. A Settings scene opens no window on its own.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var spotify: SpotifyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon or menu bar. LSUIElement already does this at launch; setting it
        // here as well makes the intent explicit.
        NSApp.setActivationPolicy(.accessory)
        let spotify = SpotifyController()
        self.spotify = spotify
        panelController = NotchPanelController(spotify: spotify)
    }
}
