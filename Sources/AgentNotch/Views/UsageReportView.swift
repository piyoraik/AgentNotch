import SwiftUI

/// 使用状況をパネル内で読むための画面。
///
/// 幅が 440pt 前後しかないので、表ではなくコストの大きい順に積んだ行として
/// 見せる。5 時間 / 週間のメーターはパネルの上端が常に描いているので、ここには
/// 置かない（`NotchContentView.expandedView`）。
struct UsageReportView: View {
    let sessions: [ClaudeSession]
    let summaries: [String: SessionSummary]
    let showsCost: Bool
    var onBack: () -> Void

    /// 稼働中のセッションはコストが 1〜2 秒ごとに増える。毎回並べ替えると
    /// 読んでいる最中に行が入れ替わるので、順序は開いた時点で決めて、
    /// セッションの顔ぶれが変わったときだけ引き直す。
    @State private var order: [String] = []

    private struct Row: Identifiable {
        let id: String
        let name: String
        let summary: SessionSummary
    }

    /// 画面に出す数字はすべてここで 1 回だけ作る。`body` の中で複数の計算
    /// プロパティから引くと、行ごとに全体の合計を取り直すことになる。
    private struct Aggregate {
        var rows: [Row] = []
        var totalCost: Double = 0
        var totalOutput: Int = 0
        var modelTotals: [(model: String, cost: Double)] = []
    }

    /// 合計も内訳も、画面に出ている行（＝生きているセッション）だけから作る。
    /// `summaries` はストアが次のスキャンを終えるまで終了済みセッションを
    /// 抱えたままなので、そちらを集計元にすると合計だけが行の和より大きく出る。
    private var aggregate: Aggregate {
        var result = Aggregate()
        var byModel: [String: Double] = [:]

        var rows = sessions.map { session in
            Row(
                id: session.sessionId,
                name: session.projectName,
                summary: summaries[session.sessionId] ?? SessionSummary()
            )
        }

        for row in rows {
            result.totalCost += row.summary.costUSD
            result.totalOutput += row.summary.tokens.output
            for (model, cost) in row.summary.costByModel {
                byModel[model, default: 0] += cost
            }
        }

        // 既知の順序を優先し、まだ順序に載っていないセッションはコスト順で
        // 後ろに付ける。
        // `uniqueKeysWithValues` は同じ sessionId が 2 つあると trap する。
        // 一覧はプロセス単位なので、再開などで重複しても落ちないようにする。
        let rank = Dictionary(
            order.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        rows.sort { lhs, rhs in
            switch (rank[lhs.id], rank[rhs.id]) {
            case let (l?, r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.summary.costUSD > rhs.summary.costUSD
            }
        }

        result.rows = rows
        result.modelTotals = byModel
            .map { (model: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
        return result
    }

    var body: some View {
        let data = aggregate

        return VStack(alignment: .leading, spacing: 10) {
            header

            if sessions.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if showsCost {
                            totalCard(data)
                        }
                        sessionSection(data)
                        if showsCost, data.modelTotals.count > 1 {
                            modelSection(data.modelTotals)
                        }
                        if showsCost {
                            disclaimer
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 14)
        .onAppear { resetOrder() }
        .onChange(of: Set(sessions.map(\.sessionId))) { _, _ in resetOrder() }
    }

    /// 並び順を今のコスト順で引き直す。
    private func resetOrder() {
        order = sessions
            .map { ($0.sessionId, summaries[$0.sessionId]?.costUSD ?? 0) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.85))

            Text("使用状況レポート")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 4)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 12)
            ClaudeMarkView(activity: .idle, size: 30)
                .opacity(0.35)
            Text("集計できるセッションがありません")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 合計

    private func totalCard(_ data: Aggregate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("推定コスト合計")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))

            Text(TokenPricing.format(data.totalCost))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(AgentBrand.accent)
                .rollingNumber()
                .animation(Motion.quick, value: data.totalCost)

            HStack(spacing: 4) {
                Text("\(data.rows.count) セッション")
                Text("·")
                Text("out \(SessionSummary.abbreviate(data.totalOutput))")
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AgentBrand.accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - セッション別

    private func sessionSection(_ data: Aggregate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("セッション別", detail: showsCost ? "コストの大きい順" : nil)

            // メニューから開くとこの画面がパネルを開いた直後の中身になるので、
            // `staggeredAppear` は付けない（CLAUDE.md の不変条件）。
            ForEach(data.rows) { row in
                sessionRow(row, totalCost: data.totalCost)
            }
        }
    }

    private func sessionRow(_ row: Row, totalCost: Double) -> some View {
        let summary = row.summary
        let share = totalCost > 0 ? summary.costUSD / totalCost : 0

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if showsCost {
                    Text(TokenPricing.format(summary.costUSD))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AgentBrand.accent.opacity(0.95))
                        .rollingNumber()
                        .animation(Motion.quick, value: summary.costUSD)
                }
            }

            if showsCost {
                shareBar(share)
            }

            HStack(spacing: 5) {
                Text(summary.shortModel ?? "—")
                    .font(.system(size: 9, design: .monospaced))
                Text("·")
                Text("ctx \(SessionSummary.abbreviate(summary.contextTokens))")
                Text("·")
                Text("out \(SessionSummary.abbreviate(summary.outputTokens))")
                if showsCost {
                    Spacer(minLength: 2)
                    Text(Self.percent(share))
                        .font(.system(size: 9, design: .rounded))
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
        }
        .padding(9)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 費用が出ているのに「0%」と出ると不具合に見えるので、丸めて 0 になる
    /// ものは「<1%」にする。
    private static func percent(_ share: Double) -> String {
        let rounded = Int((share * 100).rounded())
        if rounded == 0, share > 0 { return "<1%" }
        return "\(rounded)%"
    }

    /// 全体に占める割合。金額だけだと桁の差が掴みにくいので、棒でも見せる。
    private func shareBar(_ share: Double) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.1))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(AgentBrand.accent.opacity(0.75))
                        .frame(width: proxy.size.width * min(max(share, 0), 1))
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: share)
                }
            }
            .clipShape(Capsule())
    }

    // MARK: - モデル別

    private func modelSection(_ totals: [(model: String, cost: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("モデル別", detail: nil)

            VStack(spacing: 5) {
                ForEach(totals, id: \.model) { entry in
                    HStack(spacing: 6) {
                        Text(entry.model.replacingOccurrences(of: "claude-", with: ""))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(TokenPricing.format(entry.cost))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(AgentBrand.accent.opacity(0.9))
                    }
                }
            }
            .padding(9)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    /// 請求額と取り違えられると困るので、画面にも必ず出す。
    private var disclaimer: some View {
        Text("定額プランはトークン単位で課金されません。表示は同じ処理を従量課金の API で回した場合の換算値です。")
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.3))
            .fixedSize(horizontal: false, vertical: true)
    }
}
