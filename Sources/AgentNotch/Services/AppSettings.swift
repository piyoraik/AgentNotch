import Combine
import Foundation
import ServiceManagement

/// User-tunable preferences, persisted in `UserDefaults` and published so the
/// stores can rebuild their timers and the windows resize when a value moves.
///
/// `@unchecked Sendable` because the stores that read it are plain
/// (non-isolated) classes; every property here is only ever touched on main.
final class AppSettings: ObservableObject, @unchecked Sendable {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    // MARK: - 表示

    @Published var showNotchPanel: Bool { didSet { write(.showNotchPanel, showNotchPanel) } }
    @Published var expandOnHover: Bool { didSet { write(.expandOnHover, expandOnHover) } }
    @Published var showUsageInNotch: Bool { didSet { write(.showUsageInNotch, showUsageInNotch) } }
    /// Cost figures are an API-equivalent estimate, not a bill, so they can be
    /// turned off for anyone who would rather not see a number they can't act on.
    @Published var showCostEstimates: Bool { didSet { write(.showCostEstimates, showCostEstimates) } }
    /// Which display the panel lives on, as a `ScreenLocator` identifier. Empty
    /// means "decide automatically"; an identifier that is no longer connected
    /// falls back to the automatic choice without being cleared.
    @Published var preferredScreenID: String { didSet { write(.preferredScreenID, preferredScreenID) } }
    /// How far the pill extends past each side of the physical notch.
    @Published var wingWidth: Double { didSet { write(.wingWidth, wingWidth) } }
    @Published var panelWidth: Double { didSet { write(.panelWidth, panelWidth) } }
    @Published var panelHeight: Double { didSet { write(.panelHeight, panelHeight) } }

    // MARK: - メニューバー

    @Published var showStatusItem: Bool { didSet { write(.showStatusItem, showStatusItem) } }
    @Published var showSessionCountInMenuBar: Bool { didSet { write(.showSessionCountInMenuBar, showSessionCountInMenuBar) } }
    @Published var showUsageInMenu: Bool { didSet { write(.showUsageInMenu, showUsageInMenu) } }
    @Published var showSessionTitlesInMenu: Bool { didSet { write(.showSessionTitlesInMenu, showSessionTitlesInMenu) } }

    // MARK: - 更新間隔

    @Published var sessionPollInterval: Double { didSet { write(.sessionPollInterval, sessionPollInterval) } }
    @Published var summaryPollInterval: Double { didSet { write(.summaryPollInterval, summaryPollInterval) } }
    @Published var transcriptPollInterval: Double { didSet { write(.transcriptPollInterval, transcriptPollInterval) } }
    @Published var usageEnabled: Bool { didSet { write(.usageEnabled, usageEnabled) } }
    @Published var usageRefreshInterval: Double { didSet { write(.usageRefreshInterval, usageRefreshInterval) } }

    // MARK: - 承認

    @Published var autoOpenOnApproval: Bool { didSet { write(.autoOpenOnApproval, autoOpenOnApproval) } }
    @Published var bounceOnApproval: Bool { didSet { write(.bounceOnApproval, bounceOnApproval) } }
    @Published var playSoundOnApproval: Bool { didSet { write(.playSoundOnApproval, playSoundOnApproval) } }
    @Published var approvalSoundName: String { didSet { write(.approvalSoundName, approvalSoundName) } }

    // MARK: - ソフトウェア更新

    /// Whether to ask GitHub for a newer release once a day. Checking is the
    /// only automatic part; downloading and installing always wait for a press.
    @Published var automaticUpdateChecks: Bool { didSet { write(.automaticUpdateChecks, automaticUpdateChecks) } }

    // MARK: - ウィンドウの状態

    /// Which pane the preferences window reopens on. Not user-facing.
    @Published var lastSettingsPane: String { didSet { write(.lastSettingsPane, lastSettingsPane) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func flag(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key.rawValue) == nil ? fallback : defaults.bool(forKey: key.rawValue)
        }
        func number(_ key: Key, _ fallback: Double) -> Double {
            defaults.object(forKey: key.rawValue) == nil ? fallback : defaults.double(forKey: key.rawValue)
        }

        showNotchPanel = flag(.showNotchPanel, true)
        expandOnHover = flag(.expandOnHover, true)
        showUsageInNotch = flag(.showUsageInNotch, true)
        showCostEstimates = flag(.showCostEstimates, true)
        preferredScreenID = defaults.string(forKey: Key.preferredScreenID.rawValue) ?? ScreenLocator.automaticIdentifier
        wingWidth = number(.wingWidth, 98)
        panelWidth = number(.panelWidth, 440)
        panelHeight = number(.panelHeight, 560)

        showStatusItem = flag(.showStatusItem, true)
        showSessionCountInMenuBar = flag(.showSessionCountInMenuBar, true)
        showUsageInMenu = flag(.showUsageInMenu, true)
        showSessionTitlesInMenu = flag(.showSessionTitlesInMenu, true)

        sessionPollInterval = number(.sessionPollInterval, 1.0)
        summaryPollInterval = number(.summaryPollInterval, 2.0)
        transcriptPollInterval = number(.transcriptPollInterval, 1.5)
        usageEnabled = flag(.usageEnabled, true)
        usageRefreshInterval = number(.usageRefreshInterval, 900)

        autoOpenOnApproval = flag(.autoOpenOnApproval, true)
        bounceOnApproval = flag(.bounceOnApproval, true)
        playSoundOnApproval = flag(.playSoundOnApproval, false)
        approvalSoundName = defaults.string(forKey: Key.approvalSoundName.rawValue) ?? "Ping"
        automaticUpdateChecks = flag(.automaticUpdateChecks, true)
        lastSettingsPane = defaults.string(forKey: Key.lastSettingsPane.rawValue) ?? "general"
    }

    /// Wipes every stored key and reloads the defaults, so the reset lands in
    /// one publish per property rather than leaving stale values behind.
    func resetToDefaults() {
        for key in Key.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }

        showNotchPanel = true
        expandOnHover = true
        showUsageInNotch = true
        showCostEstimates = true
        preferredScreenID = ScreenLocator.automaticIdentifier
        wingWidth = 98
        panelWidth = 440
        panelHeight = 560

        showStatusItem = true
        showSessionCountInMenuBar = true
        showUsageInMenu = true
        showSessionTitlesInMenu = true

        sessionPollInterval = 1.0
        summaryPollInterval = 2.0
        transcriptPollInterval = 1.5
        usageEnabled = true
        usageRefreshInterval = 900

        autoOpenOnApproval = true
        bounceOnApproval = true
        playSoundOnApproval = false
        approvalSoundName = "Ping"
        automaticUpdateChecks = true
        lastSettingsPane = "general"
    }

    private func write(_ key: Key, _ value: Any) {
        defaults.set(value, forKey: key.rawValue)
    }

    private enum Key: String, CaseIterable {
        case showNotchPanel, expandOnHover, showUsageInNotch, showCostEstimates
        case preferredScreenID
        case wingWidth, panelWidth, panelHeight
        case showStatusItem, showSessionCountInMenuBar, showUsageInMenu, showSessionTitlesInMenu
        case sessionPollInterval, summaryPollInterval, transcriptPollInterval
        case usageEnabled, usageRefreshInterval
        case autoOpenOnApproval, bounceOnApproval, playSoundOnApproval, approvalSoundName
        case automaticUpdateChecks
        case lastSettingsPane
    }
}

// MARK: - Launch at login

extension AppSettings {
    /// Backed by the login-item service rather than our defaults, so it stays
    /// truthful when the user toggles it in System Settings.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("AgentNotch: login item toggle failed: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}
