import Foundation

enum ApprovalDecision: String, Sendable {
    case allow
    case deny
    /// Hand the decision back to the terminal's own prompt.
    case passthrough
}

struct ApprovalRequest: Sendable, Identifiable, Equatable {
    let id: String
    let sessionId: String
    let cwd: String
    let toolName: String
    /// The most meaningful part of `tool_input` for the tool at hand.
    let detail: String
    let receivedAt: Date

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    init?(json: [String: Any]) {
        guard let toolName = json["tool_name"] as? String else { return nil }
        self.toolName = toolName
        self.sessionId = json["session_id"] as? String ?? ""
        self.cwd = json["cwd"] as? String ?? ""
        self.id = json["tool_use_id"] as? String ?? UUID().uuidString
        self.receivedAt = Date()

        let input = json["tool_input"] as? [String: Any] ?? [:]
        self.detail = ApprovalRequest.summarize(toolName: toolName, input: input)
    }

    private static func summarize(toolName: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url", "pattern", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return String(text.prefix(400))
    }
}
