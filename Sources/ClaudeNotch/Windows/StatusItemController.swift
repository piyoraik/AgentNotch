import AppKit
import Combine

/// Menu bar presence. Doubles as the app's only quit affordance, since
/// LSUIElement apps have no Dock icon or app menu.
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let monitor: SessionMonitor
    private let summaries: SummaryStore
    private let usage: UsageStore
    private var cancellables = Set<AnyCancellable>()

    init(monitor: SessionMonitor, summaries: SummaryStore, usage: UsageStore) {
        self.monitor = monitor
        self.summaries = summaries
        self.usage = usage
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        statusItem.button?.image = NSImage(
            systemSymbolName: "sparkle",
            accessibilityDescription: "Claude Code sessions"
        )
        statusItem.button?.imagePosition = .imageLeading

        monitor.$sessions
            .combineLatest(summaries.$summaries, usage.$snapshot)
            .sink { [weak self] sessions, summaries, usage in
                self?.update(sessions: sessions, summaries: summaries, usage: usage)
            }
            .store(in: &cancellables)
    }

    private func update(
        sessions: [ClaudeSession],
        summaries: [String: SessionSummary],
        usage: UsageSnapshot
    ) {
        statusItem.button?.title = " \(sessions.count)"

        let menu = NSMenu()
        menu.addItem(usageItem(for: usage))
        menu.addItem(.separator())
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
                if let summary {
                    let context = SessionSummary.abbreviate(summary.contextTokens)
                    let output = SessionSummary.abbreviate(summary.outputTokens)
                    item.toolTip = summary.title
                    let subtitle = "\(summary.title ?? "—")  —  \(context) ctx / \(output) out"
                    item.attributedTitle = NSAttributedString(
                        string: "\(marker) \(session.projectName)\n\(subtitle)",
                        attributes: [.font: NSFont.menuFont(ofSize: 13)]
                    )
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "ClaudeNotch を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        statusItem.menu = menu
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
