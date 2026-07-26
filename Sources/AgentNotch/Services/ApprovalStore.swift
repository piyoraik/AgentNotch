import Combine
import Foundation

/// Holds approval requests awaiting a decision.
///
/// The socket that produces them belongs to `HookServer`, which serves the
/// notice side too; this store only owns the queue of unanswered questions.
/// Sound and Dock attention live in `AlertCenter`, so the three things that
/// can poke the user can't drift apart.
///
/// `@unchecked Sendable` because `handle` is called from the server's
/// connection queue; every mutation below is hopped onto main first.
final class ApprovalStore: ObservableObject, @unchecked Sendable {
    struct Pending: Identifiable {
        let request: ApprovalRequest
        let respond: @Sendable (ApprovalDecision) -> Void

        var id: String { request.id }
    }

    @Published private(set) var pending: [Pending] = []

    private let alwaysAllow: AlwaysAllowStore
    /// Session id → when this store last answered a permission for it. Owned by
    /// main. Kept because a request that a standing rule allows never becomes
    /// `pending`, so "is this session blocked" can't see it at all.
    private var lastDecisionAt: [String: Date] = [:]

    init(alwaysAllow: AlwaysAllowStore = .shared) {
        self.alwaysAllow = alwaysAllow
    }

    /// Entry point from `HookServer`, called off the main queue.
    func handle(_ request: ApprovalRequest, respond: @escaping @Sendable (ApprovalDecision) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                respond(.passthrough)
                return
            }

            // A standing approval answers silently: no panel, no alert.
            if self.alwaysAllow.allows(request) {
                self.lastDecisionAt[request.sessionId] = Date()
                respond(.allow)
                return
            }

            self.pending.append(Pending(request: request, respond: respond))
        }
    }

    func resolve(_ pending: Pending, with decision: ApprovalDecision) {
        self.pending.removeAll { $0.id == pending.id }
        lastDecisionAt[pending.request.sessionId] = Date()
        pending.respond(decision)
    }

    /// Grants this request and stores a rule so the same thing is allowed
    /// without asking again.
    func allowAlways(_ pending: Pending, rule: AlwaysAllowRule) {
        alwaysAllow.add(rule)
        resolve(pending, with: .allow)
    }

    /// Whether a given session is already blocked on a question in the panel.
    /// The CLI fires its own `Notification` for the same permission prompt, and
    /// a notice about a question the user is already looking at is noise.
    func isBlocked(sessionId: String) -> Bool {
        pending.contains { $0.request.sessionId == sessionId }
    }

    /// Whether this store has just answered a permission for the session.
    ///
    /// The CLI's `Notification` about a permission arrives alongside the
    /// `PermissionRequest` we answer ourselves, so by the time the notice is
    /// ready to show there may be nothing pending and nothing waiting in the
    /// terminal either — the session took the answer and carried on. A notice
    /// then points at a session that isn't asking anything.
    func answeredRecently(sessionId: String, within window: TimeInterval) -> Bool {
        guard let last = lastDecisionAt[sessionId] else { return false }
        return Date().timeIntervalSince(last) <= window
    }
}
