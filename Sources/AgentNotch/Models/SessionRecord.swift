import Foundation

/// 終わったセッション 1 本。`~/.claude/projects/**/*.jsonl` から復元する。
///
/// 実行中の一覧に出る `ClaudeSession` とは出所が違う。あちらは
/// `~/.claude/sessions/<pid>.json` が元で、プロセスが終わると消える。履歴が
/// 見るのはトランスクリプトそのものなので、pid も status も無い代わりに、
/// 何ヶ月前のものでも同じように読める。
struct SessionRecord: Identifiable, Equatable {
    let sessionId: String
    let url: URL
    let summary: SessionSummary
    /// 中身から時刻が 1 つも取れなかったときの控え。空の JSONL でも
    /// 日付の島に落とせるようにしておく。
    let modified: Date

    var id: String { sessionId }

    /// トランスクリプトは cwd を持っているが、壊れている・空のときのために
    /// ディレクトリ名（エンコード済みの cwd）から復元する経路も残す。
    var projectName: String {
        if let cwd = summary.cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        let encoded = url.deletingLastPathComponent().lastPathComponent
        return encoded.split(separator: "-").last.map(String.init) ?? encoded
    }

    var cwd: String? { summary.cwd }

    /// 見出し。`ai-title` が付く前に終わったセッションは最後のプロンプトで、
    /// それも無ければ日付だけの行になる。
    var title: String? {
        guard let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }

    var startedAt: Date { summary.firstActivity ?? summary.lastActivity ?? modified }
    var endedAt: Date { summary.lastActivity ?? modified }

    var duration: TimeInterval {
        max(endedAt.timeIntervalSince(startedAt), 0)
    }

    /// 中身の無いトランスクリプト。`claude` を起動してすぐ閉じただけでも
    /// ファイルは残るので、一覧に出す前に落とす。
    var isEmpty: Bool {
        summary.userTurns == 0 && summary.tokens.output == 0
    }

    /// 一覧の絞り込み。本文まで見ると全ファイルを開くことになるので、
    /// 行に出ている文字（タイトル・プロジェクト・ブランチ・パス）だけを見る。
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = [title, projectName, summary.gitBranch, cwd, summary.model]
            .compactMap { $0?.lowercased() }
        return haystack.contains { $0.contains(needle) }
    }

    /// "1h21m" / "12m" / "40s"。振り返りでは秒まで要らないが、短い
    /// セッションが全部「0m」になると区別が付かない。
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return "\(total / 3600)h\((total % 3600) / 60)m"
        }
        if total >= 60 {
            return "\(total / 60)m"
        }
        return "\(total)s"
    }
}
