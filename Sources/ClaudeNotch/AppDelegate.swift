import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var monitor: SessionMonitor!
    private var summaries: SummaryStore!
    private var approvals: ApprovalStore!
    private var usage: UsageStore!
    private var notchController: NotchWindowController!
    private var statusItemController: StatusItemController!
    private var settingsController: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        monitor = SessionMonitor(settings: settings)
        summaries = SummaryStore(monitor: monitor, settings: settings)
        approvals = ApprovalStore(settings: settings)
        approvals.start()
        usage = UsageStore(settings: settings)
        usage.start()

        settingsController = SettingsWindowController(settings: settings)
        statusItemController = StatusItemController(
            monitor: monitor,
            summaries: summaries,
            usage: usage,
            settings: settings,
            openSettings: { [weak self] in self?.settingsController.present() }
        )
        notchController = NotchWindowController(
            monitor: monitor,
            summaries: summaries,
            approvals: approvals,
            usage: usage,
            settings: settings
        )
        notchController.show()
    }

    /// Relaunching from the Finder or `open` is the way back in when the user
    /// has hidden both the status item and the notch panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsController.present()
        return true
    }

    /// `open -a ClaudeNotch` on an already-running instance goes here rather
    /// than through reopen, so cover both.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !settings.showStatusItem, !settings.showNotchPanel else { return }
        settingsController.present()
    }
}
