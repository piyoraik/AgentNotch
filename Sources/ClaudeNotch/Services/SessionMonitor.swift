import Combine
import Foundation

/// Polls `~/.claude/sessions/*.json`, the live status files the `claude` CLI
/// writes per running process, and republishes the currently alive sessions.
final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    private let sessionsDirectory: URL
    private var timer: Timer?

    init() {
        sessionsDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)

        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        timer?.invalidate()
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
