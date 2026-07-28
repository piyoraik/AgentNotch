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
            //
            // Never for a tool that exists to ask the user something: "allow"
            // is not an answer to a question, and Claude Code would fall back
            // to the terminal prompt with nobody watching for it.
            if !request.requiresInteraction, self.alwaysAllow.allows(request) {
                self.lastDecisionAt[request.sessionId] = Date()
                respond(.allow)
                return
            }

            self.pending.append(Pending(request: request, respond: respond))
            self.scheduleExpiry(of: request)
        }
    }

    /// Answers a request nobody got to, just before the bridge gives up.
    ///
    /// Two things go wrong without this. The card outlives the bridge, and since
    /// the panel refuses to collapse while anything is pending
    /// (`NotchWindowController`), one abandoned request pins the panel open with
    /// buttons that write into a closed pipe. And letting the window run out is
    /// not neutral: measured, an unanswered request is allowed — no terminal
    /// prompt appears and Claude Code applies its own default — so silence
    /// granted everything the panel had asked about.
    ///
    /// Answering at `decisionDeadline` keeps that from being the outcome. It is
    /// still fail-open in the sense the bridge means: no failure path here
    /// blocks a session, and a session that gets a denial carries on and can say
    /// so. Deliberately not the bridge's job — it must stay a dumb relay.
    private func scheduleExpiry(of request: ApprovalRequest) {
        DispatchQueue.main.asyncAfter(deadline: .now() + request.secondsLeft()) { [weak self] in
            guard let self,
                  let index = self.pending.firstIndex(where: { $0.id == request.id })
            else { return }
            let abandoned = self.pending.remove(at: index)
            // Counts as this store having answered: `NoticeStore` would
            // otherwise raise "要応答" about a permission just settled here.
            self.lastDecisionAt[request.sessionId] = Date()
            abandoned.respond(request.expiryDecision)
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
