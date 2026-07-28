import Foundation

enum ApprovalDecision: Sendable, Equatable {
    case allow
    /// `allow` carrying a replacement `tool_input`, already serialized as a
    /// JSON object.
    ///
    /// The only decision Claude Code accepts for a tool that asks the user
    /// something. Read out of the CLI: the `PermissionRequest` hook path bails
    /// with `if (!updatedInput && tool.requiresUserInteraction()) return null`
    /// — "the hook didn't settle it" — and the terminal prompt comes up anyway.
    /// With `updatedInput` present the check is skipped and the tool runs on
    /// whatever the panel put in it. That is how an answer gets back.
    case answer(Data)
    case deny
    /// Hand the decision back to the terminal's own prompt.
    case passthrough
}

/// One question from `AskUserQuestion`, shaped so the panel can offer the same
/// choices the terminal would.
struct ApprovalQuestion: Sendable, Equatable, Identifiable {
    struct Option: Sendable, Equatable, Identifiable {
        let label: String
        let detail: String
        /// The CLI renders this next to the focused option; ASCII mockups and
        /// code snippets arrive here.
        let preview: String?

        var id: String { label }
    }

    let question: String
    /// Short chip the CLI shows above the question ("アプリ名", "Approach").
    let header: String
    let multiSelect: Bool
    let options: [Option]

    var id: String { question }
}

/// What the request actually does, shaped so the panel can render it the way
/// the terminal would rather than dumping raw JSON.
enum ApprovalBody: Sendable, Equatable {
    case command(String)
    case diff(old: String, new: String)
    case text(String)
    case questions([ApprovalQuestion])
    case none
}

struct ApprovalRequest: Sendable, Identifiable, Equatable {
    /// How long the bridge waits for an answer before failing open.
    ///
    /// Must match `responseTimeout` in `Sources/Bridge/main.swift`: the bridge
    /// exits on its own and nothing tells us it did, so this is the only thing
    /// that says when a card has stopped being answerable.
    static let responseWindow: TimeInterval = 120

    /// When this side answers on the user's behalf rather than let the window
    /// run out.
    ///
    /// Inside the bridge's window on purpose. Measured twice — a subagent's
    /// `Read` and a `WebFetch`, both left untouched — an unanswered request is
    /// *allowed*: the bridge fails open, no terminal prompt appears, and Claude
    /// Code applies its own default. So "walked away from the panel" was the
    /// same as pressing 許可. A decision sent after the bridge has gone writes
    /// into a closed pipe and changes nothing, hence the ten seconds of margin.
    static let decisionDeadline: TimeInterval = 110

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
    /// The kind of subagent that asked (`general-purpose`, `Explore`, …), or nil
    /// when this is the session's own turn.
    ///
    /// Measured against the real hook: a call made inside a subagent carries
    /// `agent_id` and `agent_type`, and nothing else marks it — `session_id`
    /// and `transcript_path` are the parent's either way, and `effort` is
    /// present only on the parent's own calls. Without this the panel can't
    /// say why the terminal is showing no prompt of its own.
    let agentType: String?
    /// `tool_input` exactly as it arrived, kept so a decision can hand it back.
    ///
    /// Answering means returning the tool's own input with the answers filled
    /// in, so the parts we don't understand have to survive the round trip
    /// untouched — rebuilding them from the parsed model would drop whatever
    /// the CLI adds next.
    let rawInput: Data
    let receivedAt: Date

    /// Tools Claude Code will not let a bare `allow` settle, because they exist
    /// to put a question in front of the user.
    ///
    /// A standing "always allow" is meaningless for these — it answers nothing
    /// — so `ApprovalStore` skips its rules for them too.
    static let interactiveTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    var requiresInteraction: Bool { Self.interactiveTools.contains(toolName) }

    var questions: [ApprovalQuestion] {
        if case .questions(let asked) = body { return asked }
        return []
    }

    /// Whether a subagent asked rather than the session itself. The parent keeps
    /// working while a background subagent waits, so the session looks busy and
    /// the terminal stays quiet.
    var isSubagent: Bool { agentType != nil }

    /// Seconds left before the panel answers on its own, floored at zero. This
    /// is the deadline worth showing: the bridge's own window ends ten seconds
    /// later and nothing can be decided in between.
    func secondsLeft(asOf now: Date = Date()) -> TimeInterval {
        max(0, Self.decisionDeadline - now.timeIntervalSince(receivedAt))
    }

    /// What to send when nobody answered in time.
    ///
    /// A permission is denied: an unanswered question is not consent, and the
    /// measured alternative is that it runs. A tool whose whole job is to ask
    /// the user something is handed to the terminal instead — denying it answers
    /// nothing, and for these the CLI really does fall back to its own prompt.
    var expiryDecision: ApprovalDecision {
        requiresInteraction ? .passthrough : .deny
    }

    /// The "go ahead" decision for this request.
    ///
    /// For the interactive tools that means echoing `tool_input` back
    /// unchanged: the content is the same, but the presence of `updatedInput`
    /// is what tells Claude Code the question has been dealt with. Without it
    /// the terminal asks again and the button did nothing.
    var allowDecision: ApprovalDecision {
        guard requiresInteraction, !rawInput.isEmpty else { return .allow }
        return .answer(rawInput)
    }

    /// Sends the picked options back as `AskUserQuestion`'s own `answers`.
    ///
    /// Keyed by question text and joined with `", "` because that is how the
    /// CLI reads them back (it splits on the same separator to check a
    /// multi-select answer against the offered labels).
    func answerDecision(_ picked: [String: [String]]) -> ApprovalDecision {
        guard var object = (try? JSONSerialization.jsonObject(with: rawInput)) as? [String: Any] else {
            return .passthrough
        }
        object["answers"] = picked
            .filter { !$0.value.isEmpty }
            .mapValues { $0.joined(separator: ", ") }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return .passthrough }
        return .answer(data)
    }

    init?(json: [String: Any]) {
        guard let toolName = json["tool_name"] as? String else { return nil }
        self.toolName = toolName
        self.sessionId = json["session_id"] as? String ?? ""
        self.cwd = json["cwd"] as? String ?? ""
        self.id = json["tool_use_id"] as? String ?? UUID().uuidString
        self.receivedAt = Date()

        let input = json["tool_input"] as? [String: Any] ?? [:]
        self.rawInput = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
        let parsed = ApprovalRequest.interpret(toolName: toolName, input: input)
        self.headline = parsed.headline
        self.body = parsed.body
        self.detail = parsed.detail

        // Only present when a subagent made the call; an empty string would
        // read as "some subagent" and is treated as absent.
        let agentType = json["agent_type"] as? String
        self.agentType = (agentType?.isEmpty ?? true) ? nil : agentType

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

        case "AskUserQuestion":
            let asked = questions(from: input["questions"])
            // A shape we can't offer choices for is worse as a half-drawn
            // picker than as the raw payload, so fall back rather than guess.
            guard !asked.isEmpty else { return (nil, .text(prettyJSON(input)), toolName) }
            let headline = asked.count > 1 ? "\(asked.count) 件の質問" : asked[0].header
            return (headline, .questions(asked), asked.map(\.question).joined(separator: " / "))

        case "ExitPlanMode":
            // The plan is usually in the session's plan file rather than the
            // input, so an empty body here is normal, not a parse failure.
            let plan = input["plan"] as? String ?? ""
            return ("プランを実行に移す", plan.isEmpty ? .none : .text(plan), plan)

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

    /// Pulls the choices out of `AskUserQuestion`'s input.
    ///
    /// A question with no usable options is dropped: the panel would show a
    /// heading with nothing to press, and the CLI itself rejects questions with
    /// fewer than two options.
    private static func questions(from value: Any?) -> [ApprovalQuestion] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let question = entry["question"] as? String, !question.isEmpty else { return nil }
            let options = (entry["options"] as? [[String: Any]] ?? [])
                .compactMap { option -> ApprovalQuestion.Option? in
                    guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                    return ApprovalQuestion.Option(
                        label: label,
                        detail: option["description"] as? String ?? "",
                        preview: option["preview"] as? String
                    )
                }
            guard !options.isEmpty else { return nil }
            return ApprovalQuestion(
                question: question,
                header: entry["header"] as? String ?? "",
                multiSelect: entry["multiSelect"] as? Bool ?? false,
                options: options
            )
        }
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
