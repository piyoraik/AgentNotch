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

    private static let contentWidth: CGFloat = 500

    init(settings: AppSettings = .shared) {
        self.settings = settings
        pane = SettingsPane(rawValue: settings.lastSettingsPane) ?? .display

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: pane.fallbackHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "ClaudeNotchSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = pane.itemIdentifier
        window.toolbar = toolbar

        // ⌘1…⌘5 reach the panes; an accessory app has no View menu to host the
        // usual shortcuts.
        window.onPaneShortcut = { [weak self] index in
            guard let self, SettingsPane.allCases.indices.contains(index) else { return false }
            self.select(SettingsPane.allCases[index])
            return true
        }

        show(pane, animated: false)
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

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let next = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(next)
    }

    private func select(_ next: SettingsPane) {
        guard next != pane else { return }
        pane = next
        settings.lastSettingsPane = next.rawValue
        window?.toolbar?.selectedItemIdentifier = next.itemIdentifier
        show(next, animated: true)
    }

    private func show(_ pane: SettingsPane, animated: Bool) {
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

        guard animated else {
            window.setFrame(frame, display: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
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
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        item.isBordered = true
        return item
    }
}

private extension SettingsPane {
    var itemIdentifier: NSToolbarItem.Identifier { .init(rawValue) }
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
