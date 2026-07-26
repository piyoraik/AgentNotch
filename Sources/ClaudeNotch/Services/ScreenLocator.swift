import AppKit

struct NotchGeometry {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    /// True when the screen physically has a notch; false means we're drawing
    /// a synthetic pill under the menu bar instead.
    let hasNotch: Bool
}

enum ScreenLocator {
    /// `NSScreen.main` follows the key window, which an accessory app never
    /// has, so it can point at an external display. Prefer whichever screen
    /// actually reports a notch.
    static func notchGeometry() -> NotchGeometry? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }) {
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

        guard let fallback = NSScreen.screens.first else { return nil }
        return NotchGeometry(screen: fallback, notchWidth: 0, notchHeight: 24, hasNotch: false)
    }
}
