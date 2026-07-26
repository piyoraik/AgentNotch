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

    /// How long to sit on a freshly arrived notice before showing it.
    ///
    /// The CLI fires `Notification` for a permission it is about to ask for,
    /// which is the same thing `PermissionRequest` is asking us — and we may
    /// answer it, from the panel or from a standing rule, before the terminal
    /// ever shows anything. Waiting gives the session time to take that answer
    /// and carry on, which is what the checks in `receive` look for. Being a
    /// few seconds late to a real one costs nothing; the user is walking back
    /// to the terminal either way.
    private static let settleDelay: TimeInterval = 5
    /// How long after we answer a permission a notice is still assumed to be
    /// about that same permission.
    private static let decisionWindow: TimeInterval = 20
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
    /// Session id → timestamp of the newest transcript entry seen. Owned by
    /// main, refreshed from every summary pass.
    private var transcriptActivity: [String: Date] = [:]
    /// Sessions whose turn we have already called finished, until they pick up
    /// work again. Owned by main.
    private var finishedSessions: Set<String> = []

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
                self?.finishedSessions.insert(finish.sessionId)
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
            // Or it was on screen, or a standing rule took it, and the session
            // already has its answer. Nothing is waiting in the terminal.
            guard !self.approvals.answeredRecently(
                sessionId: notice.sessionId,
                within: Self.decisionWindow
            ) else { return }
            // A session that hasn't done anything in minutes isn't stuck on a
            // question; it is just open. Saying so every minute is noise.
            guard self.wasRecentlyActive(notice.sessionId) else { return }
            // Its turn ended cleanly and we already said so. The CLI nudges
            // about sessions left sitting at the prompt, and "you have the
            // ball" is not worth saying twice in two different ways.
            guard !self.finishedSessions.contains(notice.sessionId) else { return }
            // And if it has written anything since the notice arrived, it kept
            // going on its own. Whatever the notification was about, it isn't
            // holding the session up.
            guard !self.hasMovedOn(notice) else { return }

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

    /// Whether the session has written to its transcript since the notice
    /// arrived — the one signal that says the session carried on by itself.
    ///
    /// The entry that prompted the notification is written before it, so a
    /// session that really is stuck leaves nothing newer behind.
    private func hasMovedOn(_ notice: AgentNotice) -> Bool {
        guard let activity = transcriptActivity[notice.sessionId] else { return false }
        return activity > notice.receivedAt
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
            // Working again: whatever it does next is a fresh turn.
            finishedSessions.remove(session.sessionId)
        }
        // Kept for `hasMovedOn`, which runs when a notice is about to be shown
        // rather than from here.
        for (id, summary) in summaries {
            if let activity = summary.lastActivity { transcriptActivity[id] = activity }
        }
        // Sessions that are gone can't be waiting on anything.
        lastActiveAt = lastActiveAt.filter { id, _ in
            sessions.contains { $0.sessionId == id }
        }
        transcriptActivity = transcriptActivity.filter { id, _ in
            sessions.contains { $0.sessionId == id }
        }
        finishedSessions = finishedSessions.filter { id in
            sessions.contains { $0.sessionId == id }
        }

        guard !notices.isEmpty else { return }
        notices.removeAll { notice in
            guard sessions.contains(where: { $0.sessionId == notice.sessionId }) else { return true }
            if hasMovedOn(notice) {
                return true
            }
            return now.timeIntervalSince(notice.receivedAt) > Self.lifetime
        }
    }
}
