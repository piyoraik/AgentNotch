import Combine
import Foundation

/// Keeps a lightweight summary for every live session, re-parsing a
/// transcript only when its file actually changes.
final class SummaryStore: ObservableObject {
    @Published private(set) var summaries: [String: SessionSummary] = [:]

    private struct CacheEntry {
        let url: URL
        var modified: Date?
        var summary: SessionSummary
    }

    private var cache: [String: CacheEntry] = [:]
    private var cancellable: AnyCancellable?
    private var timer: Timer?
    private var lastSessions: [ClaudeSession] = []

    init(monitor: SessionMonitor) {
        cancellable = monitor.$sessions.sink { [weak self] sessions in
            self?.lastSessions = sessions
            self?.refresh(for: sessions)
        }

        // A transcript can grow without the session file changing, so poll
        // independently of session-list updates.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh(for: self.lastSessions)
        }
    }

    private func refresh(for sessions: [ClaudeSession]) {
        let liveIds = Set(sessions.map(\.sessionId))
        cache = cache.filter { liveIds.contains($0.key) }

        for session in sessions {
            let id = session.sessionId

            let url: URL
            if let existing = cache[id]?.url {
                url = existing
            } else if let resolved = TranscriptReader.transcriptURL(for: session) {
                url = resolved
            } else {
                continue
            }

            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let entry = cache[id], entry.modified == modified {
                continue
            }

            let summary = TranscriptReader.loadSummary(from: url)
            cache[id] = CacheEntry(url: url, modified: modified, summary: summary)
        }

        let next = cache.mapValues(\.summary)
        if next != summaries {
            summaries = next
        }
    }
}
