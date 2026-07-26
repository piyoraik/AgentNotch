import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var monitor: SessionMonitor!
    private var summaries: SummaryStore!
    private var approvals: ApprovalStore!
    private var notices: NoticeStore!
    private var alerts: AlertCenter!
    private var hooks: HookInstaller!
    private var hookServer: HookServer!
    private var usage: UsageStore!
    private var updates: UpdateStore!
    private var history: HistoryStore!
    private var notchController: NotchWindowController!
    private var statusItemController: StatusItemController!
    private var settingsController: SettingsWindowController!
    /// 押されるまで作らない。窓を建てた時点で SwiftUI のビューが生き始め、
    /// 誰も見ていない一覧が毎秒の publish で評価され続ける。
    private var historyController: HistoryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        monitor = SessionMonitor(settings: settings)
        summaries = SummaryStore(monitor: monitor, settings: settings)
        approvals = ApprovalStore()
        notices = NoticeStore(monitor: monitor, summaries: summaries, approvals: approvals, settings: settings)
        alerts = AlertCenter(monitor: monitor, approvals: approvals, notices: notices, settings: settings)

        hookServer = HookServer(
            approval: { [approvals] request, respond in approvals?.handle(request, respond: respond) },
            notice: { [notices] notice in notices?.receive(notice) }
        )
        hookServer.start()

        // フックが指しているのは .app の外にあるブリッジのコピーなので、アプリを
        // 更新しただけでは古いままになる。登録済みの人が黙って壊れるのを避ける
        // ため、既に置いてあるものだけ配置し直す（新規の登録はしない）。
        hooks = HookInstaller()
        hooks.refreshInstalledBridge()

        usage = UsageStore(settings: settings)
        usage.start()
        updates = UpdateStore(settings: settings)
        updates.start()

        // 履歴は開いたときだけ走査する。ここではまだディスクを読まない。
        history = HistoryStore()

        settingsController = SettingsWindowController(settings: settings, updates: updates, hooks: hooks)
        statusItemController = StatusItemController(
            monitor: monitor,
            summaries: summaries,
            usage: usage,
            updates: updates,
            settings: settings,
            openSettings: { [weak self] in self?.settingsController.present() },
            // The notch controller is built just below; the closure only runs
            // once the user picks the item, so the ordering is fine.
            openReport: { [weak self] in self?.notchController.showReport() },
            openHistory: { [weak self] in self?.presentHistory() }
        )
        notchController = NotchWindowController(
            monitor: monitor,
            summaries: summaries,
            approvals: approvals,
            notices: notices,
            alerts: alerts,
            usage: usage,
            settings: settings
        )
        notchController.show()
    }

    /// 履歴ウィンドウは初回に押されたときだけ建てる。以後は同じ窓を出し直す
    /// ので、スクロール位置も選択も残る。
    @MainActor
    private func presentHistory() {
        if historyController == nil {
            historyController = HistoryWindowController(store: history, monitor: monitor, settings: settings)
        }
        historyController?.present()
    }

    /// Relaunching from the Finder or `open` is the way back in when the user
    /// has hidden both the status item and the notch panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsController.present()
        return true
    }

    /// `open -a AgentNotch` on an already-running instance goes here rather
    /// than through reopen, so cover both.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !settings.showStatusItem, !settings.showNotchPanel else { return }
        settingsController.present()
    }
}
