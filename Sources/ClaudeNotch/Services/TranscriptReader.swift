import Foundation

/// Parses the JSONL transcript Claude Code appends per session under
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`.
enum TranscriptReader {
    /// Keeps the detail pane bounded on long-running sessions.
    private static let messageLimit = 60

    static func transcriptURL(for session: ClaudeSession) -> URL? {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)

        // Claude Code encodes the cwd by replacing "/" and "." with "-".
        let encoded = session.cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let direct = projects
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("\(session.sessionId).jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }

        // Fall back to scanning, since the encoding isn't contractual.
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(session.sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Like `load`, but skips building the message list — this runs for every
    /// visible session, not just the selected one.
    static func loadSummary(from url: URL) -> SessionSummary {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return SessionSummary()
        }

        var summary = SessionSummary()
        var lastPrompt: String?

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            switch type {
            case "ai-title":
                summary.title = object["aiTitle"] as? String
            case "last-prompt":
                lastPrompt = object["lastPrompt"] as? String
            case "assistant":
                guard let message = object["message"] as? [String: Any] else { continue }
                if let model = message["model"] as? String { summary.model = model }
                if let usage = message["usage"] as? [String: Any] {
                    let input = usage["input_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                    summary.contextTokens = input + cacheRead + cacheWrite
                    summary.outputTokens += usage["output_tokens"] as? Int ?? 0
                }
                if let date = date(from: object["timestamp"]) { summary.lastActivity = date }
            default:
                break
            }
        }

        if summary.title == nil { summary.title = lastPrompt }
        return summary
    }

    static func load(from url: URL) -> SessionDetail {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return SessionDetail()
        }

        var detail = SessionDetail()
        var messages: [TranscriptMessage] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            switch type {
            case "ai-title":
                detail.title = object["aiTitle"] as? String
            case "assistant":
                ingestAssistant(object, into: &detail, messages: &messages)
            case "user":
                ingestUser(object, messages: &messages)
            default:
                break
            }
        }

        detail.messages = Array(messages.suffix(messageLimit))
        return detail
    }

    private static func ingestAssistant(
        _ object: [String: Any],
        into detail: inout SessionDetail,
        messages: inout [TranscriptMessage]
    ) {
        guard let message = object["message"] as? [String: Any] else { return }

        if let model = message["model"] as? String {
            detail.model = model
        }

        if let usage = message["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0

            detail.tokens.input += input
            detail.tokens.output += output
            detail.tokens.cacheRead += cacheRead
            detail.tokens.cacheWrite += cacheWrite
            detail.tokens.context = input + cacheRead + cacheWrite
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return }
        var text = ""
        var tools: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String ?? "")
            case "tool_use":
                if let name = block["name"] as? String { tools.append(name) }
            default:
                break
            }
        }

        guard !text.isEmpty || !tools.isEmpty else { return }
        messages.append(
            TranscriptMessage(
                id: object["uuid"] as? String ?? UUID().uuidString,
                role: .assistant,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                toolNames: tools,
                timestamp: date(from: object["timestamp"])
            )
        )
    }

    private static func ingestUser(_ object: [String: Any], messages: inout [TranscriptMessage]) {
        guard let message = object["message"] as? [String: Any] else { return }

        // A user record is either a typed prompt (string content) or a
        // tool_result echoed back to the model, which we skip.
        guard let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        messages.append(
            TranscriptMessage(
                id: object["uuid"] as? String ?? UUID().uuidString,
                role: .user,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                toolNames: [],
                timestamp: date(from: object["timestamp"])
            )
        )
    }

    private static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}
