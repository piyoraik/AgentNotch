import Foundation

/// Parses the JSONL transcript Claude Code appends per session under
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`.
enum TranscriptReader {
    /// Keeps the detail pane bounded on long-running sessions.
    private static let messageLimit = 60
    /// Each recall surfaces at most a handful, but a long session accumulates.
    /// One disk read per entry follows, so this stays bounded too.
    private static let memoryLimit = 20

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

    /// Where a summary scan left off, so the next one only has to read what
    /// the CLI appended. Transcripts reach megabytes, and re-reading one every
    /// couple of seconds per session is what made the UI stutter.
    struct SummaryScan {
        /// Title and prompt are carried separately: a later prompt must not be
        /// shadowed by an earlier one that was only standing in for a title.
        var summary: SessionSummary {
            var summary = accumulated
            summary.title = aiTitle ?? lastPrompt
            return summary
        }

        fileprivate var accumulated = SessionSummary()
        fileprivate var aiTitle: String?
        fileprivate var lastPrompt: String?
        /// Byte offset of the first line not yet consumed.
        fileprivate var offset: UInt64 = 0
    }

    /// Reads only the bytes appended since `scan` was produced. A file that
    /// shrank was rewritten (compaction), so that scan restarts from zero.
    static func scanSummary(from url: URL, resuming scan: SummaryScan = SummaryScan()) -> SummaryScan {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return scan }
        defer { try? handle.close() }

        var scan = scan
        let size = (try? handle.seekToEnd()) ?? 0
        if size < scan.offset {
            scan = SummaryScan()
        }
        guard size > scan.offset else { return scan }

        try? handle.seek(toOffset: scan.offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return scan }

        // The CLI may be mid-append, so stop at the last complete line and
        // leave the partial one for the next pass.
        guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else { return scan }
        let complete = chunk[chunk.startIndex...lastNewline]
        scan.offset += UInt64(complete.count)

        ingestSummaryLines(complete, into: &scan)
        return scan
    }

    /// Like `load`, but skips building the message list — this runs for every
    /// visible session, not just the selected one.
    static func loadSummary(from url: URL) -> SessionSummary {
        scanSummary(from: url).summary
    }

    private static func ingestSummaryLines(_ bytes: Data, into scan: inout SummaryScan) {
        var summary = scan.accumulated
        var aiTitle = scan.aiTitle
        var lastPrompt = scan.lastPrompt
        defer {
            scan.accumulated = summary
            scan.aiTitle = aiTitle
            scan.lastPrompt = lastPrompt
        }

        for line in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            switch type {
            case "ai-title":
                aiTitle = object["aiTitle"] as? String
            case "last-prompt":
                lastPrompt = object["lastPrompt"] as? String
            case "user":
                // 履歴だけが読む項目。日付の解釈は最初の 1 本でしか走らない
                // ようにガードしてある（プロファイル上いちばん重い処理）。
                if summary.firstActivity == nil { summary.firstActivity = date(from: object["timestamp"]) }
                if let cwd = object["cwd"] as? String { summary.cwd = cwd }
                if let branch = object["gitBranch"] as? String, !branch.isEmpty { summary.gitBranch = branch }
                if let message = object["message"] as? [String: Any], message["content"] is String {
                    summary.userTurns += 1
                }
            case "assistant":
                if let cwd = object["cwd"] as? String { summary.cwd = cwd }
                if let branch = object["gitBranch"] as? String, !branch.isEmpty { summary.gitBranch = branch }
                guard let message = object["message"] as? [String: Any] else { continue }
                let model = message["model"] as? String
                if let model { summary.model = model }
                if let usage = message["usage"] as? [String: Any] {
                    let input = usage["input_tokens"] as? Int ?? 0
                    let output = usage["output_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0

                    summary.tokens.input += input
                    summary.tokens.output += output
                    summary.tokens.cacheRead += cacheRead
                    summary.tokens.cacheWrite += cacheWrite
                    summary.tokens.context = input + cacheRead + cacheWrite

                    // Priced here rather than from the totals, because the
                    // model can change partway through a session.
                    let cost = TokenPricing.cost(
                        input: input,
                        output: output,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite,
                        model: model
                    ) ?? 0
                    summary.costUSD += cost
                    if let model, cost > 0 {
                        summary.costByModel[model, default: 0] += cost
                    }
                }
                if let date = date(from: object["timestamp"]) {
                    if summary.firstActivity == nil { summary.firstActivity = date }
                    summary.lastActivity = date
                }
            default:
                break
            }
        }
    }

    /// - Parameters:
    ///   - messageLimit: `nil` で全発言。ノッチのパネルは末尾だけで足りるが、
    ///     履歴は途中が読めないと振り返りにならないので上限を外して呼ぶ。
    ///   - memoryLimit: 同上。
    static func load(
        from url: URL,
        messageLimit: Int? = messageLimit,
        memoryLimit: Int? = memoryLimit
    ) -> SessionDetail {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return SessionDetail()
        }

        var detail = SessionDetail()
        var messages: [TranscriptMessage] = []
        var memories = MemoryTrail()

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            switch type {
            case "ai-title":
                detail.title = object["aiTitle"] as? String
            case "assistant":
                ingestAssistant(object, into: &detail, messages: &messages, memories: &memories)
            case "user":
                ingestUser(object, messages: &messages)
            case "attachment":
                ingestAttachment(object, memories: &memories)
            default:
                break
            }
        }

        detail.messages = messageLimit.map { Array(messages.suffix($0)) } ?? messages
        detail.memories = memories.resolved(limit: memoryLimit ?? .max)
        return detail
    }

    /// The memory files a session touched, in the order they first appeared.
    ///
    /// A file can show up both ways — recalled, then opened to check it. The
    /// recall is the more informative of the two, so it wins the row.
    private struct MemoryTrail {
        private var order: [String] = []
        private var origins: [String: MemoryReference.Origin] = [:]

        mutating func note(_ path: String, as origin: MemoryReference.Origin) {
            guard !path.isEmpty, MemoryReference.isMemoryPath(path) else { return }
            guard let existing = origins[path] else {
                order.append(path)
                origins[path] = origin
                return
            }
            if existing == .touched, origin == .recalled {
                origins[path] = .recalled
            }
        }

        func resolved(limit: Int) -> [MemoryReference] {
            order.prefix(limit).map { path in
                MemoryReference(
                    path: path,
                    origin: origins[path] ?? .touched,
                    summary: frontmatterDescription(atPath: path)
                )
            }
        }
    }

    /// Collects the memory files the CLI recalled into the session.
    ///
    /// Synthesized entries carry their body inline and have no file behind
    /// them; they're skipped, since there is nothing to open.
    private static func ingestAttachment(_ object: [String: Any], memories: inout MemoryTrail) {
        guard let attachment = object["attachment"] as? [String: Any],
              attachment["type"] as? String == "relevant_memories",
              let recalled = attachment["memories"] as? [[String: Any]]
        else { return }

        for memory in recalled {
            guard let path = memory["path"] as? String else { continue }
            memories.note(path, as: .recalled)
        }
    }

    /// Reads the `description:` line out of a memory's frontmatter. Written to
    /// stop at the closing fence so a body mentioning "description" can't be
    /// picked up, and to give up quietly on a file that has since been deleted.
    private static func frontmatterDescription(atPath path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return nil }
            guard line.hasPrefix("description:") else { continue }
            let value = line.dropFirst("description:".count)
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func ingestAssistant(
        _ object: [String: Any],
        into detail: inout SessionDetail,
        messages: inout [TranscriptMessage],
        memories: inout MemoryTrail
    ) {
        guard let message = object["message"] as? [String: Any] else { return }

        let model = message["model"] as? String
        if let model {
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

            // 途中でモデルが変わったセッションは、それぞれの単価で
            // 計算しないと金額がずれる。合計とは別に持っておく。
            if let model {
                var perModel = detail.tokensByModel[model] ?? TokenStats()
                perModel.input += input
                perModel.output += output
                perModel.cacheRead += cacheRead
                perModel.cacheWrite += cacheWrite
                // context は「直近ターンの入力側」なので合算しない。
                perModel.context = input + cacheRead + cacheWrite
                detail.tokensByModel[model] = perModel
            }
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
                // Read / Write / Edit のどれでも入力は `file_path`。ツール名で
                // 絞らないのは、増えても同じ書式なら拾えるようにするため。
                if let input = block["input"] as? [String: Any],
                   let path = input["file_path"] as? String {
                    memories.note(path, as: .touched)
                }
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

    /// Building an `ISO8601DateFormatter` per timestamp was the single hottest
    /// thing in the app. These are value types, so they cost nothing per call
    /// and are safe to share across the queues that parse transcripts.
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    /// Timestamps carry fractional seconds, which the plain style rejects.
    private static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = try? fractionalStyle.parse(string) { return date }
        return try? plainStyle.parse(string)
    }
}
