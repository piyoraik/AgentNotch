import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var summaries: SummaryStore!
    private var approvals: ApprovalStore!
    private var usage: UsageStore!
    private var notchController: NotchWindowController!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        monitor = SessionMonitor()
        summaries = SummaryStore(monitor: monitor)
        approvals = ApprovalStore()
        approvals.start()
        usage = UsageStore()
        usage.start()

        statusItemController = StatusItemController(monitor: monitor, summaries: summaries, usage: usage)
        notchController = NotchWindowController(
            monitor: monitor,
            summaries: summaries,
            approvals: approvals,
            usage: usage
        )
        notchController.show()
    }
}
