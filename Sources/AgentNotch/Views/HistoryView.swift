import AppKit
import SwiftUI

/// 履歴ウィンドウの UI 状態。検索欄はツールバー（AppKit）、一覧と本文は
/// SwiftUI と持ち主が分かれるので、両方が見る値をここに置く。
@MainActor
final class HistoryUIState: ObservableObject {
    @Published var query = ""
    @Published var selection: String?
}

/// 日付と時刻の書式。一覧と本文で揃える。
enum HistoryFormat {
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "今日" }
        if calendar.isDateInYesterday(date) { return "昨日" }
        return dayFormatter.string(from: date)
    }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static let dayFormatter = formatter("yMMMdEEE")
    private static let timeFormatter = formatter("Hmm")
    private static let stampFormatter = formatter("yMMMdHmm")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

/// 明るい地では `AgentBrand.accent`（ミント）が読めないので、履歴の強調は
/// 同じパレットのアズールを使う。色は増やさない。
private let historyAccent = AgentBrand.azure

// MARK: - サイドバー

/// 左の一覧。`NSSplitViewItem(sidebarWithViewController:)` に載るので、
/// 地は敷かずに素材を透かす。
struct HistorySidebarView: View {
    @ObservedObject var store: HistoryStore
    /// `SessionMonitor` はここでは購読しない（毎秒の publish で一覧全体が
    /// 作り直される）。実行中の印は `LiveDot` の中だけで見る。
    let monitor: SessionMonitor
    @ObservedObject var state: HistoryUIState
    @ObservedObject var settings: AppSettings

    var body: some View {
        let groups = Self.group(store.records.filter { $0.matches(state.query) })

        Group {
            if groups.isEmpty {
                placeholder
            } else {
                List(selection: $state.selection) {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.records) { record in
                                HistoryRow(
                                    record: record,
                                    monitor: monitor,
                                    showsCost: settings.showCostEstimates
                                )
                                .tag(record.sessionId)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                // サイドバーの素材を透かす。敷いたままだと、ツールバーの下だけ
                // 色が変わって切り継ぎに見える。
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { store.refresh() }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Spacer()
            if !store.hasScanned {
                ProgressView().controlSize(.small)
            } else {
                Text(state.query.isEmpty ? "履歴がありません" : "一致するセッションがありません")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    // MARK: 日付の島

    struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let records: [SessionRecord]
    }

    /// 終了時刻の日で束ねる。振り返りは「いつの話か」から辿る。
    static func group(_ records: [SessionRecord]) -> [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [SessionRecord]] = [:]

        for record in records {
            let day = calendar.startOfDay(for: record.endedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(record)
        }

        return order.map { day in
            DayGroup(
                id: day,
                title: HistoryFormat.day(day, calendar: calendar),
                records: buckets[day] ?? []
            )
        }
    }
}

/// 一覧の 1 行。探しているのはタイトルなので、いちばん上に置いて 1 行で切る。
/// プロジェクトと数字はその下に降ろす。
private struct HistoryRow: View {
    let record: SessionRecord
    let monitor: SessionMonitor
    let showsCost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                LiveDot(monitor: monitor, sessionId: record.sessionId)
                Text(record.title ?? "（タイトルなし）")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(meta)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [record.projectName]
        if let branch = record.summary.gitBranch { parts.append(branch) }
        return parts.joined(separator: " · ")
    }

    private var meta: String {
        var parts = [
            HistoryFormat.time(record.endedAt),
            SessionRecord.formatDuration(record.duration),
            "\(record.summary.userTurns) turns",
        ]
        if showsCost { parts.append(TokenPricing.format(record.summary.costUSD)) }
        return parts.joined(separator: " · ")
    }
}

/// 実行中かどうかだけを見る点。`SessionMonitor` の購読はこの粒度に留める。
/// 終わったセッションでは場所も取らない。
private struct LiveDot: View {
    @ObservedObject var monitor: SessionMonitor
    let sessionId: String

    var body: some View {
        if monitor.sessions.contains(where: { $0.sessionId == sessionId }) {
            Circle()
                .fill(historyAccent)
                .frame(width: 5, height: 5)
                .help("実行中")
        }
    }
}

// MARK: - 本文

/// 右のペイン。見出しは動かさず、会話だけがスクロールする。長いセッションを
/// 追っているときに、どのセッションを読んでいるのか見失わないようにする。
struct HistoryDetailPane: View {
    @ObservedObject var store: HistoryStore
    let monitor: SessionMonitor
    @ObservedObject var state: HistoryUIState
    @ObservedObject var settings: AppSettings

    private var record: SessionRecord? {
        guard let id = state.selection else { return nil }
        return store.records.first { $0.sessionId == id }
    }

    var body: some View {
        Group {
            if let record {
                content(record)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            AgentMarkView(activity: .idle, size: 34)
                .opacity(0.4)
            Text("セッションを選ぶと、そのときのやり取りが読めます")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func content(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HistoryHeader(
                record: record,
                monitor: monitor,
                showsCost: settings.showCostEstimates
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            conversation(record)
        }
    }

    @ViewBuilder
    private func conversation(_ record: SessionRecord) -> some View {
        if let detail = store.detail {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !detail.memories.isEmpty {
                        HistoryMemories(memories: detail.memories)
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(detail.messages) { message in
                        HistoryMessageView(message: message)
                    }
                    if detail.messages.isEmpty {
                        Text("読み込めるやり取りがありません")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 別のセッションに移ったら先頭から読ませる。
            .id(record.sessionId)
        } else {
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("トランスクリプトを読み込み中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// 見出し。1 行目にタイトルと操作、2 行目に居場所、3 行目に数字。
/// 数字をカードで大きく出すと会話より目立ってしまうので、1 行に畳む。
private struct HistoryHeader: View {
    let record: SessionRecord
    let monitor: SessionMonitor
    let showsCost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.title ?? record.projectName)
                    .font(.system(size: 16, weight: .semibold))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                LiveBadge(monitor: monitor, sessionId: record.sessionId)

                Spacer(minLength: 8)

                actions
            }

            Text(location)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(numbers)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var location: String {
        var parts = [record.projectName]
        if let branch = record.summary.gitBranch { parts.append(branch) }
        if let model = record.summary.shortModel { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    private var numbers: String {
        var parts = [
            "\(HistoryFormat.stamp(record.startedAt)) – \(HistoryFormat.time(record.endedAt))",
            SessionRecord.formatDuration(record.duration),
            "\(record.summary.userTurns) turns",
            "out \(SessionSummary.abbreviate(record.summary.tokens.output))",
        ]
        if showsCost { parts.append(TokenPricing.format(record.summary.costUSD)) }
        return parts.joined(separator: " · ")
    }

    /// 振り返りの次にやることは、だいたい「その場所を開く」か「続きをやる」。
    /// 見出しの右端にアイコンで置いて、本文の幅を削らない。
    private var actions: some View {
        HStack(spacing: 2) {
            if let cwd = record.cwd {
                iconButton("folder", help: "プロジェクトを開く（\(cwd)）") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                }
            }
            iconButton("arrow.clockwise", help: "再開コマンドをコピー（claude --resume \(record.sessionId)）") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("claude --resume \(record.sessionId)", forType: .string)
            }
            iconButton("doc.text.magnifyingglass", help: "トランスクリプトを Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([record.url])
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// 実行中のときだけ出す。終わったセッションには何も描かない。
private struct LiveBadge: View {
    @ObservedObject var monitor: SessionMonitor
    let sessionId: String

    var body: some View {
        if monitor.sessions.contains(where: { $0.sessionId == sessionId }) {
            Text("実行中")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(historyAccent.opacity(0.15))
                .foregroundStyle(historyAccent)
                .clipShape(Capsule())
        }
    }
}

/// 参照したメモリ。会話の前に、畳んだ札で置く。
private struct HistoryMemories: View {
    let memories: [MemoryReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("参照したメモリ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(memories) { memory in
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: memory.path))
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: memory.origin == .recalled ? "brain" : "doc.text")
                                .font(.system(size: 10))
                                .foregroundStyle(historyAccent.opacity(memory.origin == .recalled ? 1 : 0.6))
                            Text(memory.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .quaternarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!memory.exists)
                    .opacity(memory.exists ? 1 : 0.5)
                    .help(memory.summary ?? memory.path)
                }
            }
        }
    }
}

/// 発言 1 件。パネルの `MessageBubble` と違って本文を切らない。振り返りで
/// 途中が読めないなら開く意味がない。
private struct HistoryMessageView: View {
    let message: TranscriptMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if message.role == .user {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ClaudeMarkView(activity: .idle, size: 10)
                }
                Text(message.role == .user ? "You" : "Claude")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(message.role == .user ? Color.secondary : historyAccent)
                if let timestamp = message.timestamp {
                    Text(HistoryFormat.time(timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !message.toolNames.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(message.toolNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .quaternarySystemFill))
                            .foregroundStyle(.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 自分の発言だけ地を敷く。会話の切れ目が拾えるうえ、Claude 側の
        // 長文を読むときに地色が変わらない。
        .padding(message.role == .user ? 10 : 0)
        .background(
            message.role == .user
                ? AnyShapeStyle(Color(nsColor: .quaternarySystemFill))
                : AnyShapeStyle(Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
