import SwiftUI

@main
struct AgentNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// An `App` needs a scene, but every window here is AppKit-owned: the
    /// preferences window belongs to `SettingsWindowController` so the status
    /// menu can open it directly.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
