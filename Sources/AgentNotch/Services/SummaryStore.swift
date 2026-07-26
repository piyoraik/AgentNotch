import Combine
import Foundation

/// Keeps a lightweight summary for every live session, reading only the bytes
/// a transcript has grown by since the last pass.
///
/// `@unchecked Sendable` because the scan runs on a background queue: `cache`
/// is touched only there, `summaries` only on main.
final class SummaryStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var summaries: [String: SessionSummary] = [:]

    private struct CacheEntry {
        let url: URL
        var modified: Date?
        var scan: TranscriptReader.SummaryScan
    }

    /// Owned by `queue`.
    private var cache: [String: CacheEntry] = [:]
    private let queue = DispatchQueue(label: "com.piyoraik.AgentNotch.summaries", qos: .utility)
    private var isScanning = false

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastSessions: [ClaudeSession] = []

    init(monitor: SessionMonitor, settings: AppSettings = .shared) {
        monitor.$sessions
            .sink { [weak self] sessions in
                self?.lastSessions = sessions
                self?.refresh(for: sessions)
            }
            .store(in: &cancellables)

        // A transcript can grow without the session file changing, so poll
        // independently of session-list updates.
        settings.$summaryPollInterval
            .removeDuplicates()
            .sink { [weak self] interval in
                self?.restartTimer(interval: interval)
            }
            .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }

    private func restartTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.5), repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh(for: self.lastSessions)
        }
    }

    private func refresh(for sessions: [ClaudeSession]) {
        // Reading and parsing megabytes of JSONL on the main thread is what
        // made the panel animation stutter; only the publish happens there.
        guard !isScanning else { return }
        isScanning = true

        queue.async { [weak self] in
            guard let self else { return }
            let next = self.scan(sessions)
            DispatchQueue.main.async {
                self.isScanning = false
                if next != self.summaries {
                    self.summaries = next
                }
            }
        }
    }

    private func scan(_ sessions: [ClaudeSession]) -> [String: SessionSummary] {
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

            let scan = TranscriptReader.scanSummary(from: url, resuming: cache[id]?.scan ?? .init())
            cache[id] = CacheEntry(url: url, modified: modified, scan: scan)
        }

        return cache.mapValues(\.scan.summary)
    }
}
