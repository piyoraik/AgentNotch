import AppKit
import Combine

/// Menu bar presence. Doubles as the app's only quit affordance, since
/// LSUIElement apps have no Dock icon or app menu.
final class StatusItemController: NSObject {
    private let monitor: SessionMonitor
    private let summaries: SummaryStore
    private let usage: UsageStore
    private let updates: UpdateStore
    private let settings: AppSettings
    private let openSettings: () -> Void
    private let openReport: () -> Void
    private var statusItem: NSStatusItem?
    /// Built once and filled in on demand; see `rebuildMenu`.
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    /// メニューバーのアイコンは動かせないので、動作中だけ色を変えて
    /// 状態を出す。描き直しは状態が変わったときだけ。
    private var isBusy = false

    init(
        monitor: SessionMonitor,
        summaries: SummaryStore,
        usage: UsageStore,
        updates: UpdateStore,
        settings: AppSettings = .shared,
        openSettings: @escaping () -> Void,
        openReport: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.summaries = summaries
        self.usage = usage
        self.updates = updates
        self.settings = settings
        self.openSettings = openSettings
        self.openReport = openReport
        super.init()

        menu.delegate = self
        // 既定の自動有効化は「action を持つ項目だけ有効」で、こちらが立てた
        // `isEnabled` を無視する。セッション行と書き出しの有効/無効は自前で
        // 決めたいので切る。
        menu.autoenablesItems = false

        settings.$showStatusItem
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setStatusItemVisible(visible)
            }
            .store(in: &cancellables)

        // Only the button is refreshed as data arrives. The menu is filled in
        // `menuNeedsUpdate`, because replacing `statusItem.menu` while the user
        // has it open closes it out from under them — and a busy session
        // publishes new token counts every couple of seconds.
        //
        // Deliberately *not* subscribed to `summaries`: the button shows a count
        // and a colour, neither of which comes from a summary. Waking it on every
        // token update relaid out the status item once per poll for nothing.
        monitor.$sessions
            .combineLatest(settings.$showSessionCountInMenuBar)
            .sink { [weak self] _, _ in
                self?.updateButton()
            }
            .store(in: &cancellables)
    }

    private func setStatusItemVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = AgentMark.statusImage(busy: false)
            item.button?.image?.accessibilityDescription = "Claude Code sessions"
            item.button?.imagePosition = .imageLeading
            item.menu = menu
            statusItem = item
            isBusy = false
            updateButton()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func updateButton() {
        guard let statusItem else { return }
        let sessions = monitor.sessions

        statusItem.button?.title = settings.showSessionCountInMenuBar ? " \(sessions.count)" : ""

        let busy = sessions.contains(where: \.isBusy)
        if busy != isBusy {
            isBusy = busy
            statusItem.button?.image = AgentMark.statusImage(busy: busy)
            statusItem.button?.image?.accessibilityDescription = "Claude Code sessions"
        }
    }

    /// Called by AppKit just before the menu opens, so what it shows is current
    /// without anything mutating it while it is on screen.
    private func rebuildMenu() {
        let sessions = monitor.sessions
        let summaries = self.summaries.summaries

        menu.removeAllItems()
        if settings.showUsageInMenu, settings.usageEnabled {
            menu.addItem(usageItem(for: usage.snapshot))
            menu.addItem(.separator())
        }

        if sessions.isEmpty {
            let item = NSMenuItem(title: "実行中のセッションはありません", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for session in sessions {
                let summary = summaries[session.sessionId]
                let marker = session.isBusy ? "●" : "○"
                // 行が押せないと、一覧が読み物なのか操作できるのか分からない。
                // パネルの端末ボタンと同じ動きにして、押せることを見た目にも出す。
                let item = NSMenuItem(
                    title: "\(marker) \(session.projectName)",
                    action: #selector(revealSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = RevealTarget(pid: session.pid, title: summary?.title)
                if let summary, settings.showSessionTitlesInMenu {
                    let context = SessionSummary.abbreviate(summary.contextTokens)
                    let output = SessionSummary.abbreviate(summary.outputTokens)
                    item.toolTip = summary.title
                    var subtitle = "\(summary.title ?? "—")  —  \(context) ctx / \(output) out"
                    if settings.showCostEstimates {
                        subtitle += " / \(TokenPricing.format(summary.costUSD))"
                    }
                    item.attributedTitle = NSAttributedString(
                        string: "\(marker) \(session.projectName)\n\(subtitle)",
                        attributes: [.font: NSFont.menuFont(ofSize: 13)]
                    )
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let reportItem = NSMenuItem(
            title: "使用状況レポート…",
            action: #selector(showReport),
            keyEquivalent: "r"
        )
        reportItem.keyEquivalentModifierMask = [.command, .shift]
        reportItem.target = self
        // 中身のないレポートを開けても読むものがないので、セッションがない
        // ときは押せなくする。
        reportItem.isEnabled = !sessions.isEmpty
        menu.addItem(reportItem)

        // 設定を開かないと更新に気づけない、という状態を作らない。降ってきた
        // ことだけ知らせて、実際に入れ替えるかは設定画面で決めてもらう。
        if let waiting = updateTitle() {
            menu.addItem(.separator())
            let item = NSMenuItem(title: waiting, action: #selector(showSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "設定…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(
            NSMenuItem(title: "AgentNotch を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
    }

    @objc private func showSettings() {
        openSettings()
    }

    /// Only the two states worth interrupting for: something to fetch, or
    /// something already fetched and waiting on a restart.
    private func updateTitle() -> String? {
        switch updates.phase {
        case .available(let update): return "バージョン \(update.version) があります…"
        case .staged(let update): return "\(update.version) を適用する準備ができました…"
        default: return nil
        }
    }

    /// The title rides along because emulators without a `tty` property
    /// (Ghostty) need it to tell two sessions in one directory apart.
    private struct RevealTarget {
        let pid: Int32
        let title: String?
    }

    @objc private func revealSession(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? RevealTarget else { return }
        TerminalLocator.reveal(pid: target.pid, title: target.title)
    }

    /// パネルをレポート画面で開く。
    @objc private func showReport() {
        openReport()
    }

    private func usageItem(for usage: UsageSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: "使用量", action: nil, keyEquivalent: "")
        item.isEnabled = false

        let title: String
        if usage.isEmpty {
            title = "使用量: \(usage.failure ?? "取得中…")"
        } else {
            title = "5h \(Self.describe(usage.fiveHour))   |   週間 \(Self.describe(usage.sevenDay))"
        }
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 13)]
        )
        return item
    }

    private static func describe(_ window: UsageWindow?) -> String {
        guard let window else { return "--" }
        guard let reset = window.resetCountdown() else { return "\(window.percent)%" }
        return "\(window.percent)% (\(reset)後)"
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
