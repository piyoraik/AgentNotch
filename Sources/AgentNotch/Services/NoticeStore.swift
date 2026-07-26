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

    private let approvals: ApprovalStore
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

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

    /// Drops notices whose session has moved on.
    ///
    /// Progress is judged by the transcript growing past the moment the notice
    /// arrived, not by the session's busy flag: what the CLI reports while it
    /// waits on its own terminal prompt isn't something we've pinned down, and
    /// guessing wrong here would clear the notice the instant it appeared.
    private func reconcile(sessions: [ClaudeSession], summaries: [String: SessionSummary]) {
        guard !notices.isEmpty else { return }
        let now = Date()
        notices.removeAll { notice in
            guard sessions.contains(where: { $0.sessionId == notice.sessionId }) else { return true }
            if let activity = summaries[notice.sessionId]?.lastActivity, activity > notice.receivedAt {
                return true
            }
            return now.timeIntervalSince(notice.receivedAt) > Self.lifetime
        }
    }
}
