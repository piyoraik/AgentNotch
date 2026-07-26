import Combine
import Foundation

/// Keeps the sessions that are waiting on the user but can't be answered from
/// the notch: plan approval, `AskUserQuestion`, or a prompt left sitting.
///
/// Nothing here changes what the CLI does — the `Notification` hook takes no
/// answer back. All this buys is knowing to look at the terminal.
///
/// `@unchecked Sendable` because `receive` is called from the hook server's
/// connection queue; every mutation below happens on main.
final class NoticeStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var notices: [AgentNotice] = []

    /// How long to sit on a freshly arrived notice before showing it. The CLI
    /// fires `Notification` for its own permission prompt as well, and that can
    /// beat our `PermissionRequest` round trip by a hair; waiting a moment lets
    /// the approval panel claim the session first and this one stay quiet.
    private static let settleDelay: TimeInterval = 1.5
    /// A notice nobody acted on shouldn't sit in the panel for the rest of the
    /// day. Answering in the terminal usually clears it long before this.
    private static let lifetime: TimeInterval = 300
    /// How recently a session must have been working for its notice to mean
    /// "it stopped to ask something".
    ///
    /// The CLI also fires `Notification` at a session that has merely been
    /// sitting idle, and people keep sessions parked — this machine had five
    /// of them. Without this window every parked terminal lights the notch a
    /// minute after it is left alone, which reads as the app inventing
    /// notifications.
    private static let activeWindow: TimeInterval = 120

    private let approvals: ApprovalStore
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    /// Session id → when it was last seen working. Owned by main.
    private var lastActiveAt: [String: Date] = [:]

    init(
        monitor: SessionMonitor,
        summaries: SummaryStore,
        approvals: ApprovalStore,
        settings: AppSettings = .shared
    ) {
        self.approvals = approvals
        self.settings = settings

        // `combineLatest` so both sides are the values just published rather
        // than the still-old ones a `@Published` willSet would hand back.
        monitor.$sessions
            .combineLatest(summaries.$summaries)
            .sink { [weak self] sessions, summaries in
                self?.reconcile(sessions: sessions, summaries: summaries)
            }
            .store(in: &cancellables)

        // A session that just stopped working is the one that might have
        // stopped to ask.
        monitor.finished
            .sink { [weak self] finish in
                self?.lastActiveAt[finish.sessionId] = finish.finishedAt
            }
            .store(in: &cancellables)

        settings.$notifyOnWaiting
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.notices.removeAll()
            }
            .store(in: &cancellables)
    }

    /// Entry point from `HookServer`, called off the main queue.
    func receive(_ notice: AgentNotice) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.settings.notifyOnWaiting else { return }
            // The same question is already on screen with buttons under it.
            guard !self.approvals.isBlocked(sessionId: notice.sessionId) else { return }
            // A session that hasn't done anything in minutes isn't stuck on a
            // question; it is just open. Saying so every minute is noise.
            guard self.wasRecentlyActive(notice.sessionId) else { return }

            self.notices.removeAll { $0.id == notice.id }
            self.notices.append(notice)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay + Self.lifetime) { [weak self] in
            // Only the notice that was scheduled here: a newer one about the
            // same session gets its own expiry.
            self?.notices.removeAll { $0.id == notice.id && $0.receivedAt == notice.receivedAt }
        }
    }

    func dismiss(_ notice: AgentNotice) {
        notices.removeAll { $0.id == notice.id }
    }

    /// Whether the session was working recently enough that a notice about it
    /// means "it stopped to ask", rather than "this terminal is still open".
    private func wasRecentlyActive(_ sessionId: String) -> Bool {
        guard let last = lastActiveAt[sessionId] else { return false }
        return Date().timeIntervalSince(last) <= Self.activeWindow
    }

    /// Drops notices whose session has moved on.
    ///
    /// Progress is judged by the transcript growing past the moment the notice
    /// arrived, not by the session's busy flag: what the CLI reports while it
    /// waits on its own terminal prompt isn't something we've pinned down, and
    /// guessing wrong here would clear the notice the instant it appeared.
    private func reconcile(sessions: [ClaudeSession], summaries: [String: SessionSummary]) {
        let now = Date()
        for session in sessions where session.isWorking {
            lastActiveAt[session.sessionId] = now
        }
        // Sessions that are gone can't be waiting on anything.
        lastActiveAt = lastActiveAt.filter { id, _ in
            sessions.contains { $0.sessionId == id }
        }

        guard !notices.isEmpty else { return }
        notices.removeAll { notice in
            guard sessions.contains(where: { $0.sessionId == notice.sessionId }) else { return true }
            if let activity = summaries[notice.sessionId]?.lastActivity, activity > notice.receivedAt {
                return true
            }
            return now.timeIntervalSince(notice.receivedAt) > Self.lifetime
        }
    }
}
