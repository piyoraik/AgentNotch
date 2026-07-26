import Foundation

enum ApprovalDecision: String, Sendable {
    case allow
    case deny
    /// Hand the decision back to the terminal's own prompt.
    case passthrough
}

/// What the request actually does, shaped so the panel can render it the way
/// the terminal would rather than dumping raw JSON.
enum ApprovalBody: Sendable, Equatable {
    case command(String)
    case diff(old: String, new: String)
    case text(String)
    case none
}

struct ApprovalRequest: Sendable, Identifiable, Equatable {
    let id: String
    let sessionId: String
    let cwd: String
    let toolName: String
    /// The line under the tool badge: Bash's own description, or the path
    /// being touched.
    let headline: String?
    let body: ApprovalBody
    /// Canonical string a standing rule matches on — the command for Bash,
    /// the path for file tools.
    let detail: String
    /// Rule patterns Claude Code itself proposed, e.g. `xcodegen generate *`.
    let suggestedRules: [String]
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
        let parsed = ApprovalRequest.interpret(toolName: toolName, input: input)
        self.headline = parsed.headline
        self.body = parsed.body
        self.detail = parsed.detail

        self.suggestedRules = ApprovalRequest.rules(from: json["permission_suggestions"])
    }

    // MARK: - Interpretation

    private static func interpret(
        toolName: String,
        input: [String: Any]
    ) -> (headline: String?, body: ApprovalBody, detail: String) {
        switch toolName {
        case "Bash", "BashOutput":
            let command = input["command"] as? String ?? ""
            return (input["description"] as? String, .command(command), command)

        case "Edit", "NotebookEdit":
            let path = input["file_path"] as? String ?? ""
            let old = input["old_string"] as? String ?? input["old_source"] as? String ?? ""
            let new = input["new_string"] as? String ?? input["new_source"] as? String ?? ""
            return (shortPath(path), .diff(old: old, new: new), path)

        case "Write":
            let path = input["file_path"] as? String ?? ""
            return (shortPath(path), .text(input["content"] as? String ?? ""), path)

        case "Read":
            let path = input["file_path"] as? String ?? ""
            return (shortPath(path), .none, path)

        case "Glob", "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String
            return (path.map(shortPath), .text(pattern), pattern)

        case "WebFetch", "WebSearch":
            let target = input["url"] as? String ?? input["query"] as? String ?? ""
            return (nil, .text(target), target)

        default:
            let pretty = prettyJSON(input)
            let key = ["command", "file_path", "path", "url", "pattern", "prompt"]
                .compactMap { input[$0] as? String }
                .first { !$0.isEmpty }
            return (nil, .text(pretty), key ?? pretty)
        }
    }

    /// Full paths overflow a 440pt panel; the trailing two components carry
    /// nearly all the meaning.
    private static func shortPath(_ path: String) -> String {
        let parts = (path as NSString).pathComponents
        guard parts.count > 2 else { return path }
        return parts.suffix(2).joined(separator: "/")
    }

    private static func prettyJSON(_ input: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    /// `permission_suggestions` carries the rule strings the CLI would have
    /// offered in its own prompt — a better default than anything we'd invent.
    private static func rules(from value: Any?) -> [String] {
        guard let suggestions = value as? [[String: Any]] else { return [] }
        return suggestions
            .filter { $0["type"] as? String == "addRules" && $0["behavior"] as? String == "allow" }
            .flatMap { $0["rules"] as? [[String: Any]] ?? [] }
            .compactMap { $0["ruleContent"] as? String }
    }
}
