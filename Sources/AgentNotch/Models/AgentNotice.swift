import Foundation

/// A `Notification` hook payload: the CLI telling us that a session is waiting
/// on the user. Unlike an approval there is nothing to answer here — the hook
/// takes no decision back — so this only ever becomes a nudge and a way into
/// the right terminal.
///
/// The events worth catching are the ones AgentNotch cannot answer itself:
/// plan approval, `AskUserQuestion`, and a session left idling on a prompt.
struct AgentNotice: Identifiable, Equatable, Sendable {
    /// One live notice per session: a newer message about the same session
    /// replaces the old one rather than stacking up.
    var id: String { sessionId }

    let sessionId: String
    let cwd: String
    let message: String
    let receivedAt: Date

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    init?(json: [String: Any]) {
        guard let message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else { return nil }
        self.message = message
        self.sessionId = json["session_id"] as? String ?? ""
        self.cwd = json["cwd"] as? String ?? ""
        self.receivedAt = Date()
    }
}
