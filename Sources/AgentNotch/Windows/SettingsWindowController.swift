import AppKit
import SwiftUI

/// Hosts the preferences window. An accessory app gets no Settings menu item,
/// so this is opened from the status menu and has to activate the app itself
/// to take focus.
///
/// The pane switcher is an `NSToolbar` in `.preference` style rather than a
/// SwiftUI `TabView`, which outside a `Settings` scene draws as a boxed inline
/// tab control. A toolbar also lets the window title track the pane and lets
/// each pane size the window to its own content.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let settings: AppSettings
    private var pane: SettingsPane
    /// Kept alive per pane so scroll position and control focus survive a
    /// round trip through the tab bar.
    private var hosts: [SettingsPane: NSHostingController<AnyView>] = [:]
    /// The tab views, so the selected one can be re-tinted from anywhere the
    /// pane changes (a click, ⌘1…⌘5, or the restored pane at launch).
    private var tabs: [SettingsPane: PaneTabView] = [:]

    private static let contentWidth: CGFloat = 500

    init(settings: AppSettings = .shared) {
        self.settings = settings
        // 旧バージョンが書いた "refresh" のような値もここで先頭ペインに落ちる。
        pane = SettingsPane(rawValue: settings.lastSettingsPane) ?? .general

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: pane.fallbackHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "AgentNotchSettings")
        toolbar.delegate = self
        // タブが自分でアイコンとラベルを描くので、ツールバー側にラベル行を
        // 確保させない。`.iconAndLabel` のままだと 14pt のラベル欄が残り、
        // 項目のビューがその上に押し込められて選択のピルとずれる。
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // `selectedItemIdentifier` は立てない。立てるとツールバーが選択のピルを
        // セル基準で描き、こちらのアイコンとラベル（引き伸ばされたビューの中央）
        // と 1.5pt ずれる。選択は `PaneTabView` が自分の bounds に描く。
        window.toolbar = toolbar

        // ⌘1…⌘5 reach the panes; an accessory app has no View menu to host the
        // usual shortcuts.
        window.onPaneShortcut = { [weak self] index in
            guard let self, SettingsPane.allCases.indices.contains(index) else { return false }
            self.select(SettingsPane.allCases[index])
            return true
        }

        show(pane)
        // Centre once the pane has set the real height, otherwise the window
        // hangs low by half the difference from the placeholder size.
        window.center()
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

    // MARK: - Panes

    @objc private func selectPane(_ sender: PaneTabView) {
        select(sender.pane)
    }

    private func select(_ next: SettingsPane) {
        guard next != pane else { return }
        pane = next
        settings.lastSettingsPane = next.rawValue
        markSelectedTab()
        show(next)
    }

    /// View-based items draw no selection of their own, so the tint is ours to
    /// keep in step with `pane`.
    private func markSelectedTab() {
        for (candidate, tab) in tabs {
            tab.isSelected = candidate == pane
        }
    }

    private func show(_ pane: SettingsPane) {
        guard let window else { return }

        let host = hosts[pane] ?? {
            let host = NSHostingController(
                rootView: AnyView(pane.view(settings: settings).frame(width: Self.contentWidth))
            )
            hosts[pane] = host
            return host
        }()

        window.title = pane.title
        window.contentViewController = host

        // Measure after install so the view is in a window and has resolved
        // its fonts; grouped forms report nothing useful before that.
        host.view.layoutSubtreeIfNeeded()
        let measured = host.view.fittingSize.height
        let height = measured > 120 ? min(measured, 760) : pane.fallbackHeight

        let target = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: height)
        )
        // Grow downward from the title bar so the tab bar stays put while the
        // window resizes under it.
        let frame = NSRect(
            x: window.frame.minX,
            y: window.frame.maxY - target.height,
            width: target.width,
            height: target.height
        )

        // ペインの切り替えもアニメーションしない。ノッチと同じ理由で、枠だけが
        // 遅れて動くと中身との差が見えてしまう。
        window.setFrame(frame, display: true)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.itemIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: identifier.rawValue) else { return nil }

        let item = NSToolbarItem(itemIdentifier: identifier)
        // ラベルはタブ側が描くので item には持たせない。両方に入れると
        // ツールバーが自前のラベルを下に重ねて二重に出る。
        item.paletteLabel = pane.title

        // AppKit だけに任せると、当たり判定はアイコンの 24×24 しかない。56pt の
        // セルに描かれるラベルとその周りの余白は無反応で、そこを押した一回目が
        // 空振りするため「タブは 2 回押さないと切り替わらない」ことになる（実測:
        // ラベル上のクリック、アイコンの 1〜3pt 横のクリックがいずれも無反応）。
        // ビューを持たせてタブ全体を押せるようにし、そのぶん選択の色は自分で塗る。
        let tab = tabs[pane] ?? {
            let tab = PaneTabView(pane: pane, target: self, action: #selector(selectPane(_:)))
            tabs[pane] = tab
            return tab
        }()
        tab.isSelected = pane == self.pane
        item.view = tab
        return item
    }
}

private extension SettingsPane {
    var itemIdentifier: NSToolbarItem.Identifier { .init(rawValue) }
}

/// One tab of the preference toolbar: the icon over the label, with the whole
/// cell — not just the icon — taking the click.
///
/// The icon and the label are laid out by hand rather than left to
/// `NSButton(imagePosition: .imageAbove)`, which packs them until they overlap
/// when the cell is shorter than it would like: the gear sat on top of 「一般」,
/// the arrow on top of 「データ更新」.
///
/// The size is deliberately generous: a tab is a target you hit while reading
/// its label, so the label and the padding around it have to be live.
private final class PaneTabView: NSControl {
    let pane: SettingsPane

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// アイコンとラベルの間。詰めるとかなの高さで触れてしまう。
    private static let gap: CGFloat = 3

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            refresh()
        }
    }

    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            needsDisplay = true
        }
    }

    init(pane: SettingsPane, target: AnyObject, action: Selector) {
        self.pane = pane
        super.init(frame: .zero)

        self.target = target
        self.action = action

        icon.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        icon.imageScaling = .scaleNone
        label.stringValue = pane.title
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        addSubview(icon)
        addSubview(label)

        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(pane.title)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 幅はこちらの言い値が通るので、ラベルの左右に余白を足して押しやすくする。
    /// 高さは言い値どおりにはならず、ツールバーがセルの空き（47pt）に詰める。
    /// ただし要求しないと内容ぴったりの高さしか渡ってこないので、上下の余白まで
    /// 押せるようにセルより大きい値を出しておく。
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(label.fittingSize.width, icon.fittingSize.width) + 16, height: 56)
    }

    override func layout() {
        super.layout()
        let iconSize = icon.fittingSize
        let labelSize = label.fittingSize
        let block = iconSize.height + Self.gap + labelSize.height
        // 塊ごと中央に置く。ピルも bounds を上下対称に詰めて描くので中心が揃う。
        let bottom = ((bounds.height - block) / 2).rounded()
        label.frame = NSRect(
            x: ((bounds.width - labelSize.width) / 2).rounded(),
            y: bottom,
            width: labelSize.width,
            height: labelSize.height
        )
        icon.frame = NSRect(
            x: ((bounds.width - iconSize.width) / 2).rounded(),
            y: bottom + labelSize.height + Self.gap,
            width: iconSize.width,
            height: iconSize.height
        )
    }

    // MARK: - Clicks

    /// アクセサリアプリなので、設定ウィンドウは前面でもキーでないことがある。
    /// 最初のクリックを活性化に食わせず、そのままタブの切り替えに使う。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isHovering = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isHovering = bounds.contains(point)
        guard bounds.contains(point), let action else { return }
        sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    // MARK: - Appearance

    /// 下地は自分の bounds を上下対称に詰めた角丸で描く。同心なので、アイコンと
    /// ラベルの塊とピルの中心が必ず一致する。ツールバー任せのピルはセルを基準に
    /// 置かれるため、こちらの内容とは 1.5pt ずれる（そのため
    /// `selectedItemIdentifier` は立てていない）。
    override func draw(_ dirtyRect: NSRect) {
        guard let fill = backgroundFill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    private var backgroundFill: NSColor? {
        if isSelected { return .controlAccentColor.withAlphaComponent(0.16) }
        if isHovering { return .labelColor.withAlphaComponent(0.08) }
        return nil
    }

    private func refresh() {
        let tint: NSColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        icon.contentTintColor = tint
        label.textColor = tint
        setAccessibilityValue(isSelected)
        needsDisplay = true
    }
}

/// Closing with ⌘W or Escape and reaching panes with ⌘1…⌘5 is muscle memory,
/// and an accessory app has no menu bar to provide the equivalents.
private final class SettingsWindow: NSWindow {
    /// Returns true when the index addressed a pane.
    var onPaneShortcut: ((Int) -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        close()
    }

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
        if let digit = Int(characters), digit >= 1, onPaneShortcut?(digit - 1) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
