import AppKit
import ColorSync

struct NotchGeometry {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    /// True when the screen physically has a notch; false means we're drawing
    /// a synthetic pill under the menu bar instead.
    let hasNotch: Bool
}

/// One connected display, as offered in the preferences picker.
struct DisplayOption: Identifiable, Hashable {
    let id: String
    let name: String
    let hasNotch: Bool
    /// Point size, shown to tell two identically named monitors apart.
    let size: CGSize
}

enum ScreenLocator {
    /// Empty means "decide automatically" — the notch screen when there is one.
    static let automaticIdentifier = ""

    /// `NSScreen.main` follows the key window, which an accessory app never
    /// has, so it can point at an external display. Prefer the screen the user
    /// picked; fall back to whichever screen actually reports a notch.
    ///
    /// The stored identifier survives a display being unplugged: while it is
    /// gone we fall back to the automatic choice, and reconnecting it moves the
    /// panel back without the user touching the setting.
    static func notchGeometry(preferring identifier: String? = nil) -> NotchGeometry? {
        if let identifier, identifier != automaticIdentifier,
           let chosen = NSScreen.screens.first(where: { self.identifier(for: $0) == identifier }) {
            return geometry(for: chosen)
        }

        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil {
            let candidate = geometry(for: screen)
            if candidate.hasNotch { return candidate }
        }

        guard let fallback = NSScreen.screens.first else { return nil }
        return geometry(for: fallback)
    }

    static func availableDisplays() -> [DisplayOption] {
        NSScreen.screens.compactMap { screen in
            guard let id = identifier(for: screen) else { return nil }
            return DisplayOption(
                id: id,
                name: screen.localizedName,
                hasNotch: screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil,
                size: screen.frame.size
            )
        }
    }

    /// Stable across reboots and re-plugging, unlike the `CGDirectDisplayID`
    /// that macOS hands out per session, so it is what we persist.
    static func identifier(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            // No UUID (rare: virtual or mirrored displays). The session-scoped
            // number is worse than nothing only if we pretend it is stable, so
            // mark it as such.
            return "display-id:\(displayID)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func geometry(for screen: NSScreen) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0, screen.auxiliaryTopLeftArea != nil {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = screen.frame.width - left - right
            if width > 0 {
                return NotchGeometry(
                    screen: screen,
                    notchWidth: width,
                    notchHeight: screen.safeAreaInsets.top,
                    hasNotch: true
                )
            }
        }

        return NotchGeometry(
            screen: screen,
            notchWidth: 0,
            notchHeight: menuBarHeight(of: screen),
            hasNotch: false
        )
    }

    /// The strip the pill hides under. Zero when this screen isn't showing a
    /// menu bar, in which case the historical 24pt keeps the pill off the edge.
    private static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        return inset > 0 ? inset : 24
    }
}
