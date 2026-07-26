import Combine
import Foundation

/// Polls `~/.claude/sessions/*.json`, the live status files the `claude` CLI
/// writes per running process, and republishes the currently alive sessions.
final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    private let sessionsDirectory: URL
    private let settings: AppSettings
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    init(settings: AppSettings = .shared) {
        self.settings = settings
        sessionsDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)

        reload()
        cancellable = settings.$sessionPollInterval
            .removeDuplicates()
            .sink { [weak self] interval in
                self?.restartTimer(interval: interval)
            }
    }

    deinit {
        timer?.invalidate()
    }

    private func restartTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.25), repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    private func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil) else {
            sessions = []
            return
        }

        let decoder = JSONDecoder()
        let next = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ClaudeSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ClaudeSession.self, from: data)
            }
            .filter(\.isProcessAlive)
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }

        // Polling runs every second; only publish when something moved.
        if next != sessions {
            sessions = next
        }
    }
}
