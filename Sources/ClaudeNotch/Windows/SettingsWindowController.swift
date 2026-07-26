import AppKit
import SwiftUI

/// Hosts the preferences window. An accessory app gets no Settings menu item,
/// so this is opened from the status menu and has to activate the app itself
/// to take focus.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClaudeNotch 設定"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ClaudeNotchSettings")
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        // .accessory apps are not activated by ordering a window front, so the
        // window would come up behind the terminal without this.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
