import Foundation

struct TokenStats: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Approximate size of the live context window: the prompt side of the
    /// most recent assistant turn.
    var context = 0

    var totalBilledInput: Int { input + cacheWrite }
}

struct TranscriptMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let toolNames: [String]
    let timestamp: Date?
}

/// A memory file the CLI surfaced into the session.
///
/// Recall arrives as an `attachment` record of type `relevant_memories`. The
/// body is only carried inline for synthesized entries — file-backed ones are
/// meant to be lazy-loaded from `path`, so the summary here is read off disk.
struct MemoryReference: Identifiable, Equatable {
    /// リコールされたのか、セッションが自分で開いた（書いた）のかは別物。
    /// 混ぜて出すと「参照した」の意味が濁るので、行のアイコンで分ける。
    enum Origin {
        /// `relevant_memories` として CLI が本体を持ち出したもの。
        case recalled
        /// Read / Write / Edit がファイルを直接触ったもの。
        case touched
    }

    var id: String { path }
    let path: String
    let origin: Origin
    /// The frontmatter `description`, when the file is still on disk. Memories
    /// can be deleted after the turn that recalled them, so this is optional.
    let summary: String?

    /// `feedback_bedrock_model_access.md` reads as noise in a narrow row.
    var name: String {
        let base = (path as NSString).lastPathComponent
        return base.hasSuffix(".md") ? String(base.dropLast(3)) : base
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// メモリ置き場は `~/.claude/**/memory/`。リポジトリが自前で持つ
    /// `memory/` ディレクトリを巻き込まないよう、両方を条件にする。
    static func isMemoryPath(_ path: String) -> Bool {
        path.hasSuffix(".md") && path.contains("/.claude/") && path.contains("/memory/")
    }
}

struct SessionDetail: Equatable {
    var title: String?
    var model: String?
    var tokens = TokenStats()
    /// Token counts split by the model that produced them. A session that
    /// switched models has to price each stretch at its own rate, so the
    /// aggregate above can't be used for cost on its own.
    var tokensByModel: [String: TokenStats] = [:]
    var messages: [TranscriptMessage] = []
    /// Memories recalled during this session, in the order they first appeared.
    var memories: [MemoryReference] = []

    /// Estimated equivalent API cost. Unrecognised models contribute nothing
    /// rather than dropping the whole figure — see `TokenPricing`.
    var costUSD: Double {
        tokensByModel.reduce(0) { total, entry in
            total + (TokenPricing.cost(of: entry.value, model: entry.key) ?? 0)
        }
    }
}

/// The cheap slice of a transcript needed to render a list row, so the
/// overview doesn't require opening each session.
struct SessionSummary: Equatable {
    var title: String?
    var model: String?
    var tokens = TokenStats()
    /// Accumulated per message while parsing, so a mid-session model switch is
    /// priced correctly without keeping the full per-model breakdown around.
    var costUSD: Double = 0
    /// Cost split by model. Only the dollar figure is kept, not the tokens:
    /// this exists so the report can total by model across every session, and
    /// carrying full `TokenStats` per model per session would not pay for itself.
    var costByModel: [String: Double] = [:]
    var lastActivity: Date?

    // 以下は履歴（`SessionRecord`）が使う項目。実行中の一覧は `ClaudeSession`
    // から同じことを知れるので読まない。終わったセッションはプロセスも
    // セッションファイルも残っていないため、トランスクリプト側から拾う。

    /// 最初のレコードの時刻。`lastActivity` との差がセッションの長さになる。
    var firstActivity: Date?
    var cwd: String?
    /// 最後に見えたブランチ。ワークツリーを移ると途中で変わるので、
    /// 「どこで終わったか」を採る。
    var gitBranch: String?
    /// 人が打ったプロンプトの数。`user` レコードには `tool_result` の
    /// 差し戻しも混ざるので、本文が文字列のものだけを数える。
    var userTurns = 0

    var contextTokens: Int { tokens.context }
    var outputTokens: Int { tokens.output }

    /// "claude-sonnet-5" reads as noise in a narrow row; "sonnet-5" doesn't.
    var shortModel: String? {
        model?.replacingOccurrences(of: "claude-", with: "")
    }

    static func abbreviate(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}
