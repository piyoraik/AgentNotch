import AppKit
import Combine

/// Menu bar presence. Doubles as the app's only quit affordance, since
/// LSUIElement apps have no Dock icon or app menu.
final class StatusItemController: NSObject {
    private let monitor: SessionMonitor
    private let summaries: SummaryStore
    private let usage: UsageStore
    private let settings: AppSettings
    private let openSettings: () -> Void
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    /// メニューバーのアイコンは動かせないので、動作中だけ色を変えて
    /// 状態を出す。描き直しは状態が変わったときだけ。
    private var isBusy = false

    init(
        monitor: SessionMonitor,
        summaries: SummaryStore,
        usage: UsageStore,
        settings: AppSettings = .shared,
        openSettings: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.summaries = summaries
        self.usage = usage
        self.settings = settings
        self.openSettings = openSettings
        super.init()

        settings.$showStatusItem
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setStatusItemVisible(visible)
            }
            .store(in: &cancellables)

        // Any of these can change what the menu renders, so rebuild on all of
        // them; the menu is cheap and only rebuilt when something moved.
        let settingsChanged = settings.$showSessionCountInMenuBar
            .combineLatest(settings.$showUsageInMenu, settings.$showSessionTitlesInMenu)
            .map { _, _, _ in () }

        monitor.$sessions
            .combineLatest(summaries.$summaries, usage.$snapshot)
            .map { _, _, _ in () }
            .merge(with: settingsChanged)
            .sink { [weak self] in
                self?.update()
            }
            .store(in: &cancellables)
    }

    private func setStatusItemVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = ClaudeMark.statusImage(busy: false)
            item.button?.image?.accessibilityDescription = "Claude Code sessions"
            item.button?.imagePosition = .imageLeading
            statusItem = item
            isBusy = false
            update()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func update() {
        guard let statusItem else { return }
        let sessions = monitor.sessions
        let summaries = self.summaries.summaries

        statusItem.button?.title = settings.showSessionCountInMenuBar ? " \(sessions.count)" : ""

        let busy = sessions.contains(where: \.isBusy)
        if busy != isBusy {
            isBusy = busy
            statusItem.button?.image = ClaudeMark.statusImage(busy: busy)
            statusItem.button?.image?.accessibilityDescription = "Claude Code sessions"
        }

        let menu = NSMenu()
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
                let item = NSMenuItem(
                    title: "\(marker) \(session.projectName)",
                    action: nil,
                    keyEquivalent: ""
                )
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
        menu.addItem(exportItem(title: "使用状況をコピー", action: #selector(copyReport), key: "c"))
        menu.addItem(exportItem(title: "レポートを保存…", action: #selector(saveReport), key: "s"))

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "設定…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(
            NSMenuItem(title: "ClaudeNotch を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        statusItem.menu = menu
    }

    @objc private func showSettings() {
        openSettings()
    }

    // MARK: - 書き出し

    private func exportItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        // 中身がないレポートを出せてしまうと、コピーしたのかどうかが
        // 分からなくなるので、セッションがないときは押せなくする。
        item.isEnabled = !monitor.sessions.isEmpty
        return item
    }

    /// Markdown をクリップボードへ。貼り先が決まっていない用途はこちら。
    @objc private func copyReport() {
        UsageReport.copyToPasteboard(
            UsageReport.markdown(
                sessions: monitor.sessions,
                summaries: summaries.summaries,
                usage: usage.snapshot
            )
        )
    }

    /// CSV をファイルへ。表計算で集計したい用途はこちら。
    @objc private func saveReport() {
        UsageReport.save(
            UsageReport.csv(sessions: monitor.sessions, summaries: summaries.summaries),
            suggestedName: UsageReport.fileName(extension: "csv")
        )
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
