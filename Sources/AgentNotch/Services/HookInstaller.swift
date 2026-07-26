import CryptoKit
import Foundation

/// Places the bridge helper and registers it in `~/.claude/settings.json`.
///
/// Doing this by hand was the one part of the setup left to the README, and it
/// is also the part that quietly rots: the hook points at a copy of the bridge
/// that lives outside the bundle (so moving the app doesn't break it), which
/// means updating AgentNotch leaves an old bridge behind talking a protocol the
/// new app may no longer speak.
///
/// Two rules keep this honest:
/// - `settings.json` is never touched without a timestamped backup beside it.
/// - Nothing is registered on the user's behalf. The only automatic action is
///   `refreshInstalledBridge()`, which re-copies a bridge the user already
///   installed. Maintaining what they opted into is not the same as opting in
///   for them.
final class HookInstaller: ObservableObject {
    /// Where the hook points. Deliberately outside the bundle: an app that gets
    /// moved, replaced, or updated must not take the hook's path with it.
    static let bridgeURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentNotch/bin", isDirectory: true)
        .appendingPathComponent("agentnotch-bridge")

    static let settingsURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// The copy shipped inside the app, built as a dependency of this target.
    static var bundledBridgeURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("agentnotch-bridge")
    }

    /// The events the bridge is registered for, with the timeout each one
    /// needs. `PermissionRequest` waits on a human, so its timeout has to clear
    /// the bridge's own 120 second wait; `Notification` answers nothing and is
    /// gone immediately.
    private static let events: [(name: String, timeout: Int)] = [
        ("PermissionRequest", 150),
        ("Notification", 10),
    ]

    enum BridgeState: Equatable {
        case missing
        /// Installed, but not the build this app ships.
        case outdated
        case current
        /// The app itself has no bridge to copy — a broken build, not a setup
        /// problem the user can fix.
        case unavailable
    }

    enum Registration: Equatable {
        case missing
        case registered
        /// Registered, but pointing somewhere else — another install, or a
        /// hand-written path from before this pane existed.
        case elsewhere(String)
        case unreadable
    }

    struct Health: Equatable {
        var bridge: BridgeState = .missing
        var permission: Registration = .missing
        var notification: Registration = .missing

        /// Approvals work. The notification hook is an extra, not a condition.
        var isReady: Bool { bridge == .current && permission == .registered }
    }

    @Published private(set) var health = Health()
    /// Set when an action failed, so the pane can say what went wrong instead
    /// of silently doing nothing.
    @Published private(set) var lastError: String?
    /// Path of the most recent `settings.json` backup, shown after a change.
    @Published private(set) var lastBackup: String?

    /// The three paths are injectable for the same reason `AGENTNOTCH_DEST`
    /// exists in the release script: this class rewrites a file that belongs to
    /// the user, and that is not something to first exercise on the real one.
    let bridgeURL: URL
    let settingsURL: URL
    let bundledBridgeURL: URL

    init(
        bridgeURL: URL = HookInstaller.bridgeURL,
        settingsURL: URL = HookInstaller.settingsURL,
        bundledBridgeURL: URL = HookInstaller.bundledBridgeURL
    ) {
        self.bridgeURL = bridgeURL
        self.settingsURL = settingsURL
        self.bundledBridgeURL = bundledBridgeURL
        refresh()
    }

    // MARK: - Inspection

    func refresh() {
        var health = Health()
        health.bridge = bridgeState()

        switch settingsObject() {
        case .failure:
            health.permission = .unreadable
            health.notification = .unreadable
        case .success(let object):
            for event in Self.events {
                let state = registration(in: object, event: event.name)
                if event.name == "PermissionRequest" {
                    health.permission = state
                } else {
                    health.notification = state
                }
            }
        }

        self.health = health
    }

    private func bridgeState() -> BridgeState {
        guard let bundled = digest(of: bundledBridgeURL) else { return .unavailable }
        guard let installed = digest(of: bridgeURL) else { return .missing }
        return bundled == installed ? .current : .outdated
    }

    /// Content hash rather than a version string: the bridge is a bare CLI with
    /// no version to ask for, and "is this the same binary" is the actual
    /// question.
    private func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func registration(in object: [String: Any], event: String) -> Registration {
        let groups = (object["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        let commands = groups
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
            .filter { $0.contains("agentnotch-bridge") }

        guard let command = commands.first else { return .missing }
        return command == self.command ? .registered : .elsewhere(command)
    }

    /// Quoted because the path runs through "Application Support" and the CLI
    /// hands the command to a shell.
    private var command: String { "'\(bridgeURL.path)'" }

    private var isDevelopmentBuild: Bool {
        bundledBridgeURL.path.contains("/DerivedData/")
    }

    // MARK: - Actions

    /// Copies the bridge and registers both hooks. The user asked for this.
    func install() {
        lastError = nil
        lastBackup = nil
        do {
            try copyBridge()
            try updateSettings { object in
                var hooks = object["hooks"] as? [String: Any] ?? [:]
                for event in Self.events {
                    var groups = (hooks[event.name] as? [[String: Any]]) ?? []
                    groups.removeAll { Self.mentionsBridge($0) }
                    groups.append([
                        "hooks": [[
                            "type": "command",
                            "command": command,
                            "timeout": event.timeout,
                        ]],
                    ])
                    hooks[event.name] = groups
                }
                object["hooks"] = hooks
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Removes our hook entries. The bridge copy stays: it is inert without a
    /// hook pointing at it, and deleting files under Application Support on the
    /// way out is more than was asked for.
    func uninstall() {
        lastError = nil
        lastBackup = nil
        do {
            try updateSettings { object in
                guard var hooks = object["hooks"] as? [String: Any] else { return }
                for event in Self.events {
                    guard var groups = hooks[event.name] as? [[String: Any]] else { continue }
                    groups.removeAll { Self.mentionsBridge($0) }
                    // Leave no empty scaffolding behind in someone else's file.
                    if groups.isEmpty {
                        hooks.removeValue(forKey: event.name)
                    } else {
                        hooks[event.name] = groups
                    }
                }
                if hooks.isEmpty {
                    object.removeValue(forKey: "hooks")
                } else {
                    object["hooks"] = hooks
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Re-copies an already-installed bridge that no longer matches the app.
    ///
    /// Called at launch. This is the one thing that happens without a press:
    /// the hook is already registered and already pointing here, so leaving a
    /// stale binary in place only means the user's approvals break in a way
    /// they have no reason to connect to having updated the app.
    func refreshInstalledBridge() {
        guard health.bridge == .outdated else { return }
        // A build out of Xcode keeps its hands off the installed setup, for the
        // same reason it refuses to install updates over itself: running a dev
        // build for a minute must not change what the machine does afterwards.
        // The button in the settings pane still works — that one was asked for.
        guard !isDevelopmentBuild else { return }
        do {
            try copyBridge()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    private func copyBridge() throws {
        let source = bundledBridgeURL
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw Failure("アプリにブリッジが同梱されていません。")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: bridgeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Replace rather than write in place: the old copy may be running right
        // now, and an executable overwritten under a live process is how you
        // get a crash instead of an approval.
        let staged = bridgeURL.appendingPathExtension("new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        _ = try fm.replaceItemAt(bridgeURL, withItemAt: staged)
    }

    // MARK: - settings.json

    private func settingsObject() -> Result<[String: Any], Error> {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .success([:])
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            guard !data.isEmpty else { return .success([:]) }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(Failure("settings.json の中身が JSON オブジェクトではありません。"))
            }
            return .success(object)
        } catch {
            return .failure(error)
        }
    }

    /// Reads, backs up, mutates, writes. The backup is not optional: this file
    /// is the user's, it holds settings that have nothing to do with us, and
    /// rewriting it through `JSONSerialization` loses their formatting.
    private func updateSettings(_ mutate: (inout [String: Any]) -> Void) throws {
        var object: [String: Any]
        switch settingsObject() {
        case .success(let existing): object = existing
        case .failure(let error): throw error
        }

        if FileManager.default.fileExists(atPath: settingsURL.path) {
            lastBackup = try backupSettings()
        }

        mutate(&object)

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private func backupSettings() throws -> String {
        let stamp = Self.stamp.string(from: Date())
        let backup = settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json.agentnotch-\(stamp).bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: settingsURL, to: backup)
        return backup.lastPathComponent
    }

    private static func mentionsBridge(_ group: [String: Any]) -> Bool {
        let hooks = (group["hooks"] as? [[String: Any]]) ?? []
        return hooks.contains { ($0["command"] as? String)?.contains("agentnotch-bridge") == true }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
