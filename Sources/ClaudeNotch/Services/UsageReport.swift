import AppKit
import Foundation

/// Renders the numbers already on screen into text you can paste or keep.
///
/// Everything here is derived from `SessionSummary` / `SessionDetail`; nothing
/// re-reads a transcript, so a report is as current as the last poll and costs
/// nothing to produce.
enum UsageReport {
    // MARK: - 全セッション

    /// Markdown, for pasting into notes or an issue.
    static func markdown(
        sessions: [ClaudeSession],
        summaries: [String: SessionSummary],
        usage: UsageSnapshot,
        generatedAt: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("# Claude Code 使用状況")
        lines.append("")
        lines.append("生成日時: \(timestamp(generatedAt))")

        if let fiveHour = usage.fiveHour {
            lines.append("5 時間ウィンドウ: \(fiveHour.percent)%\(resetSuffix(fiveHour))")
        }
        if let sevenDay = usage.sevenDay {
            lines.append("週間ウィンドウ: \(sevenDay.percent)%\(resetSuffix(sevenDay))")
        }
        lines.append("")

        guard !sessions.isEmpty else {
            lines.append("実行中のセッションはありません。")
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("| プロジェクト | タイトル | モデル | Context | Output | Cache read | Cache write | 推定コスト |")
        lines.append("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |")

        var totals = TokenStats()
        var totalCost = 0.0
        for session in sessions {
            let summary = summaries[session.sessionId] ?? SessionSummary()
            totals.input += summary.tokens.input
            totals.output += summary.tokens.output
            totals.cacheRead += summary.tokens.cacheRead
            totals.cacheWrite += summary.tokens.cacheWrite
            totalCost += summary.costUSD

            // Built as an array rather than a `+` chain: a long chain of
            // interpolated concatenations blows up Swift's type checker.
            let cells: [String] = [
                escape(session.projectName),
                escape(summary.title ?? "—"),
                escape(summary.shortModel ?? "—"),
                String(summary.tokens.context),
                String(summary.tokens.output),
                String(summary.tokens.cacheRead),
                String(summary.tokens.cacheWrite),
                TokenPricing.format(summary.costUSD),
            ]
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }

        lines.append("")
        lines.append("合計 output \(totals.output) トークン / 推定コスト \(TokenPricing.format(totalCost))")
        lines.append("")
        lines.append("> 定額プランはトークン単位で課金されないため、コストは同じ処理を従量課金の API で回した場合の換算値。")
        return lines.joined(separator: "\n") + "\n"
    }

    /// CSV, for a spreadsheet. Raw token counts and an unrounded cost, so the
    /// columns can be summed without losing precision to display formatting.
    static func csv(
        sessions: [ClaudeSession],
        summaries: [String: SessionSummary],
        generatedAt: Date = Date()
    ) -> String {
        var rows = [
            "generated_at,project,session_id,title,model,input,output,cache_read,cache_write,context,cost_usd,last_activity"
        ]
        let stamp = generatedAt.formatted(iso8601)

        for session in sessions {
            let summary = summaries[session.sessionId] ?? SessionSummary()
            let activity = summary.lastActivity.map { $0.formatted(iso8601) } ?? ""
            rows.append([
                stamp,
                session.projectName,
                session.sessionId,
                summary.title ?? "",
                summary.model ?? "",
                String(summary.tokens.input),
                String(summary.tokens.output),
                String(summary.tokens.cacheRead),
                String(summary.tokens.cacheWrite),
                String(summary.tokens.context),
                TokenPricing.exact(summary.costUSD),
                activity,
            ].map(quote).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - 単一セッション

    static func markdown(session: ClaudeSession, detail: SessionDetail) -> String {
        var lines: [String] = []
        lines.append("# \(detail.title ?? session.displayName)")
        lines.append("")
        lines.append("- パス: `\(session.cwd)`")
        lines.append("- セッション: `\(session.sessionId)`")
        lines.append("- 推定コスト: **\(TokenPricing.format(detail.costUSD))**")
        lines.append("")
        lines.append("| モデル | Input | Output | Cache read | Cache write | 推定コスト |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")

        // Sorted so the same session always renders the same way; an unsorted
        // dictionary would reshuffle the rows between copies.
        for (model, tokens) in detail.tokensByModel.sorted(by: { $0.key < $1.key }) {
            let cost = TokenPricing.cost(of: tokens, model: model)
            let cells: [String] = [
                escape(model),
                String(tokens.input),
                String(tokens.output),
                String(tokens.cacheRead),
                String(tokens.cacheWrite),
                cost.map(TokenPricing.format) ?? "不明",
            ]
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }

        lines.append("")
        lines.append("> 定額プランはトークン単位で課金されないため、コストは同じ処理を従量課金の API で回した場合の換算値。")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 出力先

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Returns the URL written, or nil when the user cancelled.
    ///
    /// アクセサリアプリはウィンドウを出しただけでは前面に来ないので、
    /// パネルを開く前に `activate` しておく。設定ウィンドウと同じ理由。
    @discardableResult
    static func save(_ text: String, suggestedName: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("ClaudeNotch: report save failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// "claude-usage-20260726-1830.csv"
    static func fileName(extension ext: String, at date: Date = Date()) -> String {
        "claude-usage-\(fileStamp(date)).\(ext)"
    }

    // MARK: - Formatting

    private static func resetSuffix(_ window: UsageWindow) -> String {
        window.resetCountdown().map { "（\($0)後にリセット）" } ?? ""
    }

    /// Markdown tables break on a bare pipe, and a newline inside a cell ends
    /// the row — both show up in titles taken from user prompts.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    /// `DateFormatter` と `ISO8601DateFormatter` はクラスで `Sendable` では
    /// ないため、static で共有しない。値型の `ISO8601FormatStyle` を使い、
    /// 固定レイアウトの 2 つは `DateComponents` から直接組む。
    private static let iso8601 = Date.ISO8601FormatStyle()

    private static func timestamp(_ date: Date) -> String {
        let parts = components(of: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year, parts.month, parts.day, parts.hour, parts.minute
        )
    }

    private static func fileStamp(_ date: Date) -> String {
        let parts = components(of: date)
        return String(
            format: "%04d%02d%02d-%02d%02d",
            parts.year, parts.month, parts.day, parts.hour, parts.minute
        )
    }

    private static func components(
        of date: Date
    ) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return (
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0
        )
    }
}
