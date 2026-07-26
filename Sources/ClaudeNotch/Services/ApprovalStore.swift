import AppKit
import Combine

/// Holds approval requests awaiting a decision, and owns the socket server
/// that produced them.
///
/// `@unchecked Sendable` because the socket server hands requests over from a
/// background queue; every mutation below is hopped onto main first.
final class ApprovalStore: ObservableObject, @unchecked Sendable {
    struct Pending: Identifiable {
        let request: ApprovalRequest
        let respond: @Sendable (ApprovalDecision) -> Void

        var id: String { request.id }
    }

    @Published private(set) var pending: [Pending] = []

    private var server: ApprovalServer?
    private let settings: AppSettings
    private let alwaysAllow: AlwaysAllowStore

    init(settings: AppSettings = .shared, alwaysAllow: AlwaysAllowStore = .shared) {
        self.settings = settings
        self.alwaysAllow = alwaysAllow
    }

    func start() {
        let server = ApprovalServer { [weak self] request, respond in
            DispatchQueue.main.async {
                guard let self else {
                    respond(.passthrough)
                    return
                }

                // A standing approval answers silently: no panel, no alert.
                if self.alwaysAllow.allows(request) {
                    respond(.allow)
                    return
                }

                self.pending.append(Pending(request: request, respond: respond))
                if self.settings.bounceOnApproval {
                    NSApp.requestUserAttention(.informationalRequest)
                }
                if self.settings.playSoundOnApproval {
                    NSSound(named: self.settings.approvalSoundName)?.play()
                }
            }
        }
        server.start()
        self.server = server
    }

    func resolve(_ pending: Pending, with decision: ApprovalDecision) {
        self.pending.removeAll { $0.id == pending.id }
        pending.respond(decision)
    }

    /// Grants this request and stores a rule so the same thing is allowed
    /// without asking again.
    func allowAlways(_ pending: Pending, rule: AlwaysAllowRule) {
        alwaysAllow.add(rule)
        resolve(pending, with: .allow)
    }
}
