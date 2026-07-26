import AppKit
import Combine
import SwiftUI

/// 履歴ウィンドウ。器は AppKit、中身は SwiftUI。
///
/// サイドバーは `NSSplitViewController` に任せる。SwiftUI の
/// `NavigationSplitView` は開閉ボタンを自前で作るが、置き場所は窓の
/// ツールバー前提なので、ツールバーの無い窓では中身の左上に落ちて
/// タイトルバーと高さが合わない。設定ウィンドウで `TabView` を捨てたのと
/// 同じ理由で、器の作法は AppKit 側に寄せる。
///
/// `NSSplitViewItem(sidebarWithViewController:)` にすると、素材・幅の記憶・
/// 畳んだ状態・`.toggleSidebar` の応答が全部付いてくる。
final class HistoryWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    private let store: HistoryStore
    private let state = HistoryUIState()
    private var cancellables = Set<AnyCancellable>()

    /// 一覧と本文を並べて置ける最小。これより狭いと左右どちらも読めない。
    private static let minimumSize = NSSize(width: 820, height: 520)

    private enum ItemID {
        static let search = NSToolbarItem.Identifier("history.search")
    }

    init(store: HistoryStore, monitor: SessionMonitor, settings: AppSettings = .shared) {
        self.store = store

        let window = HistoryWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 980, height: 660)),
            // `.fullSizeContentView` が無いと、サイドバーの素材がツールバーの
            // 下まで伸びず、上端だけ色が変わって見える。
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "履歴"
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.setFrameAutosaveName("AgentNotchHistory")

        super.init(window: window)

        let sidebar = NSHostingController(
            rootView: HistorySidebarView(
                store: store,
                monitor: monitor,
                state: state,
                settings: settings
            )
        )
        let detail = NSHostingController(
            rootView: HistoryDetailPane(
                store: store,
                monitor: monitor,
                state: state,
                settings: settings
            )
        )

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 460
        split.addSplitViewItem(detailItem)
        // 幅はドラッグしたところを覚える。開くたびに既定へ戻ると、
        // 一覧を広げて読む使い方ができない。
        split.splitView.autosaveName = "AgentNotchHistorySplit"

        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "AgentNotchHistory")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        // タイトルもツールバーの帯に収める。二段になると、読み物の窓なのに
        // 上だけ厚くなる。
        window.toolbarStyle = .unified

        // 行を選んだら本文を読む。ビューではなく器が繋ぐ（一覧と本文が
        // 別のホスティングに分かれていて、どちらの持ち物でもないため）。
        state.$selection
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self else { return }
                self.store.select(self.store.records.first { $0.sessionId == id })
            }
            .store(in: &cancellables)

        // 走査し直して選択が消えていたら外す。残っていれば読んだままにする。
        store.$records
            .sink { [weak self] records in
                guard let self, let selection = self.state.selection else { return }
                if !records.contains(where: { $0.sessionId == selection }) {
                    self.state.selection = nil
                }
            }
            .store(in: &cancellables)

        // 覚えた枠が無い初回だけ真ん中に置く。
        if !window.setFrameUsingName("AgentNotchHistory") {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        // 閉じている間に増えたセッションを拾う。履歴はタイマーで追わない
        // ので、走査するのは前面に出すこの瞬間だけ。
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `.sidebarTrackingSeparator` がツールバーの区切りをサイドバーの
        // 境目に貼り付ける。これが無いと、畳んだときに検索欄だけが
        // 取り残されて位置がずれる。
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == ItemID.search else { return nil }

        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.searchField.placeholderString = "タイトル・プロジェクト"
        item.searchField.delegate = self
        item.resignsFirstResponderWithCancel = true
        return item
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        state.query = field.stringValue
    }
}

/// ⌘W で閉じ、⌘F で検索欄へ。アクセサリアプリにはメニューバーが無いので、
/// 標準のキー操作は窓ごとに用意する。
private final class HistoryWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let characters = event.charactersIgnoringModifiers
        else {
            return super.performKeyEquivalent(with: event)
        }

        if characters == "w" {
            close()
            return true
        }
        if characters == "f", let search = toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            search.beginSearchInteraction()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
