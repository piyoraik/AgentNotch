import Combine
import Foundation

/// A session that just handed control back to the user: it was busy on the
/// previous pass and is idle on this one, with the process still alive.
struct FinishedSession: Identifiable, Equatable {
    let sessionId: String
    let projectName: String
    let pid: Int32
    /// How long the session stayed busy. Measured from the first poll that saw
    /// it working, so a session that was already running when AgentNotch
    /// launched is timed from launch rather than from its real start.
    let busyDuration: TimeInterval
    let finishedAt: Date

    var id: String { sessionId }
}

/// Polls `~/.claude/sessions/*.json`, the live status files the `claude` CLI
/// writes per running process, and republishes the currently alive sessions.
final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Busy → idle transitions. An event rather than a `@Published` value: a
    /// value would have to be cleared afterwards, and every clear would be a
    /// second publish that subscribers have to learn to ignore.
    let finished = PassthroughSubject<FinishedSession, Never>()

    /// Where each session is in its current turn. Owned by main, like every
    /// other member here: `reload()` only ever runs on the main run loop.
    private var progress: [String: Progress] = [:]

    private struct Progress {
        /// Start of the stretch the session has been working for, cleared once
        /// its end has been announced.
        var workingSince: Date?
        /// First poll that saw it idle since then.
        var idleSince: Date?
        var announced = false
    }

    /// How long a session has to stay idle before its turn counts as over.
    ///
    /// The CLI passes through `waiting` in the middle of a run, and any state
    /// that isn't `idle` already counts as working — but a settle time costs
    /// nothing and keeps one odd poll from being read as a finished turn.
    private static let settleDelay: TimeInterval = 2

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
            // Nothing readable means nothing to compare against next time; a
            // session that comes back is a fresh one, not a finished one.
            progress.removeAll()
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

        detectFinished(in: next)

        // Polling runs every second; only publish when something moved.
        if next != sessions {
            sessions = next
        }
    }

    /// Compares this pass against the previous one and announces the sessions
    /// whose turn came to an end.
    ///
    /// Only sessions that are still in the list count: one that disappeared
    /// while working means the terminal went away mid-run, which is not
    /// something to congratulate the user about.
    private func detectFinished(in next: [ClaudeSession]) {
        let now = Date()
        var carried: [String: Progress] = [:]

        for session in next {
            var entry = progress[session.sessionId] ?? Progress()

            if session.isWorking {
                entry.workingSince = entry.workingSince ?? now
                entry.idleSince = nil
                entry.announced = false
            } else if let start = entry.workingSince, !entry.announced {
                let idleSince = entry.idleSince ?? now
                entry.idleSince = idleSince
                if now.timeIntervalSince(idleSince) >= Self.settleDelay {
                    entry.announced = true
                    entry.workingSince = nil
                    finished.send(
                        FinishedSession(
                            sessionId: session.sessionId,
                            projectName: session.projectName,
                            pid: session.pid,
                            busyDuration: idleSince.timeIntervalSince(start),
                            finishedAt: idleSince
                        )
                    )
                }
            }

            carried[session.sessionId] = entry
        }

        progress = carried
    }
}
