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

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    func start() {
        let server = ApprovalServer { [weak self] request, respond in
            DispatchQueue.main.async {
                guard let self else {
                    respond(.passthrough)
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
}
