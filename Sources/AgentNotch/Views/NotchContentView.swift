import SwiftUI

struct NotchContentView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var uiState: NotchUIState
    @ObservedObject var transcripts: TranscriptStore
    @ObservedObject var summaries: SummaryStore
    @ObservedObject var approvals: ApprovalStore
    @ObservedObject var alwaysAllow: AlwaysAllowStore = .shared
    @ObservedObject var notices: NoticeStore
    @ObservedObject var alerts: AlertCenter
    @ObservedObject var usage: UsageStore
    @ObservedObject var settings: AppSettings
    /// Width of the physical notch to leave uncovered; 0 on screens without one.
    let notchWidth: CGFloat
    let collapsedHeight: CGFloat

    private var busyCount: Int {
        monitor.sessions.filter(\.isBusy).count
    }

    private var showsUsage: Bool { settings.showUsageInNotch && settings.usageEnabled }

    private var hasApproval: Bool { !approvals.pending.isEmpty }

    private var hasNotice: Bool { !notices.notices.isEmpty }

    /// マークとふちの色はこの一つの状態から決める。表示の意味が
    /// ばらけないよう、判定はここだけに置く。
    private var activity: MarkActivity {
        if hasApproval { return .alert }
        return busyCount > 0 ? .busy : .idle
    }

    private var selectedSession: ClaudeSession? {
        guard let id = uiState.selectedSessionId else { return nil }
        return monitor.sessions.first { $0.sessionId == id }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: uiState.isExpanded ? 22 : 10,
            bottomTrailingRadius: uiState.isExpanded ? 22 : 10,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        Group {
            if uiState.isExpanded {
                expandedView
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else {
                collapsedView
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shape.fill(Color.black))
        // 承認待ちのあいだだけ縁が灯る。パネルを見ていなくても
        // ノッチの輪郭で気付ける。
        .overlay {
            shape
                .strokeBorder(
                    hasApproval ? Color.yellow.opacity(0.55) : Color.white.opacity(0.06),
                    lineWidth: hasApproval ? 1.2 : 0.5
                )
                .shadow(color: hasApproval ? .yellow.opacity(0.35) : .clear, radius: 6)
                .allowsHitTesting(false)
        }
        .animation(Motion.quick, value: hasApproval)
        .onHover { hovering in
            // With hover expansion off the pill only opens on click, but a
            // hover that ends still has to release an already-open panel.
            if settings.expandOnHover || !hovering {
                uiState.isHovering = hovering
            }
        }
        .onTapGesture {
            guard !settings.expandOnHover, !uiState.isExpanded else { return }
            uiState.isPinned = true
        }
        .onChange(of: uiState.selectedSessionId) { _, _ in
            transcripts.select(selectedSession)
        }
    }

    // MARK: - Collapsed

    private var collapsedView: some View {
        HStack(spacing: 0) {
            leftWing.frame(maxWidth: .infinity)
            if notchWidth > 0 {
                Color.clear.frame(width: notchWidth)
            }
            rightWing.frame(maxWidth: .infinity)
        }
        .frame(height: collapsedHeight)
        .padding(.horizontal, 10)
    }

    /// Gains a second row when the meters are on, so the wings stay balanced
    /// across the notch; otherwise busy/idle stays opposite as it always was.
    private var leftWing: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                AgentMarkView(activity: activity, size: 12, introduces: true)
                Text("\(monitor.sessions.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .rollingNumber()
                    .animation(Motion.quick, value: monitor.sessions.count)
            }
            if showsUsage {
                busyIndicator(compact: true)
            }
        }
    }

    /// Sits under the session count while the meters occupy the right wing,
    /// and moves across to fill that wing when the meters are turned off.
    private func busyIndicator(compact: Bool) -> some View {
        HStack(spacing: 4) {
            PulsingDot(isActive: busyCount > 0, size: compact ? 5 : 6)
            Text(busyCount > 0 ? "busy" : "idle")
                .font(.system(size: compact ? 9 : 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.opacity)
                .animation(Motion.quick, value: busyCount > 0)
        }
    }

    /// Usage is the resting state here, and only something that is **still
    /// stuck** may take the slot: an approval blocked on us, a session blocked
    /// on the terminal.
    ///
    /// 終わった知らせをここに出さない。1 ターンごとに数秒だけメーターが
    /// 消えて戻るため、使用量が読み込み直されているように見えるうえ、
    /// 「何も起きていないのにバッジが出ている」と読める。完了は音と、
    /// 一覧の当該行に出す。
    private var rightWing: some View {
        HStack(spacing: 4) {
            if hasApproval {
                WingBadge(
                    symbol: "exclamationmark.shield.fill",
                    text: approvals.pending.count > 1 ? "承認 \(approvals.pending.count)" : "承認",
                    tint: .yellow
                )
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else if hasNotice {
                WingBadge(
                    symbol: "bell.badge.fill",
                    text: notices.notices.count > 1 ? "要応答 \(notices.notices.count)" : "要応答",
                    tint: AgentBrand.amber
                )
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else {
                Group {
                    if showsUsage {
                        UsageWingView(snapshot: usage.snapshot)
                    } else {
                        busyIndicator(compact: false)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(Motion.quick, value: approvals.pending.count)
        .animation(Motion.quick, value: notices.notices.count)
    }

    // MARK: - Expanded

    private var expandedView: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: collapsedHeight + 6)

            if approvals.pending.isEmpty, settings.usageEnabled {
                UsageStripView(snapshot: usage.snapshot)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }

            // 承認と違って画面を占領させない。答えるのはターミナルなので、
            // どの子画面を見ていても目に入る位置に置いておくだけでよい。
            if approvals.pending.isEmpty, !notices.notices.isEmpty {
                VStack(spacing: 6) {
                    ForEach(notices.notices) { notice in
                        NoticeBanner(
                            notice: notice,
                            onReveal: monitor.sessions
                                .first { $0.sessionId == notice.sessionId }
                                .map { session in
                                    {
                                        TerminalLocator.reveal(
                                            pid: session.pid,
                                            title: summaries.summaries[session.sessionId]?.title
                                        )
                                        notices.dismiss(notice)
                                    }
                                },
                            onDismiss: { notices.dismiss(notice) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .offset(y: -8)))
            }

            // 一覧 → 詳細は右から、戻るときは左から。どこへ移動したのかが
            // アニメーションの向きで分かるようにしている。
            Group {
                if let pending = approvals.pending.first {
                    ApprovalView(
                        pending: pending,
                        remaining: approvals.pending.count,
                        onDecision: { approvals.resolve(pending, with: $0) },
                        onAlwaysAllow: { approvals.allowAlways(pending, rule: $0) },
                        onReveal: monitor.sessions
                            .first { $0.sessionId == pending.request.sessionId }
                            .map { session in
                                {
                                    TerminalLocator.reveal(
                                        pid: session.pid,
                                        title: summaries.summaries[session.sessionId]?.title
                                    )
                                }
                            }
                    )
                    .id(pending.id)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                } else if uiState.showingAlwaysAllowRules {
                    AlwaysAllowRulesView(store: alwaysAllow) {
                        uiState.showingAlwaysAllowRules = false
                    }
                    .transition(Motion.drill(forward: true))
                } else if uiState.showingReport {
                    UsageReportView(
                        sessions: monitor.sessions,
                        summaries: summaries.summaries,
                        showsCost: settings.showCostEstimates,
                        onBack: { uiState.showingReport = false }
                    )
                    .transition(Motion.drill(forward: true))
                } else if let session = selectedSession {
                    SessionDetailView(
                        session: session,
                        detail: transcripts.detail,
                        showsCost: settings.showCostEstimates,
                        onBack: { uiState.selectedSessionId = nil }
                    )
                    .transition(Motion.drill(forward: true))
                } else {
                    sessionList
                        .transition(Motion.drill(forward: false))
                }
            }
            .animation(Motion.navigate, value: uiState.selectedSessionId)
            .animation(Motion.navigate, value: uiState.showingAlwaysAllowRules)
            .animation(Motion.navigate, value: uiState.showingReport)
            .animation(Motion.navigate, value: approvals.pending.first?.id)
        }
        .padding(.bottom, 14)
        .animation(Motion.quick, value: notices.notices.map(\.id))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AppLockup(
                    title: "Claude Code",
                    subtitle: busyCount > 0 ? "\(busyCount) 件が実行中" : "待機中",
                    markSize: 16,
                    titleSize: 12,
                    activity: activity
                )
                .animation(Motion.quick, value: busyCount)
                Spacer()
                if !alwaysAllow.rules.isEmpty {
                    Button {
                        uiState.isPinned = true
                        uiState.showingAlwaysAllowRules = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 9))
                            Text("\(alwaysAllow.rules.count)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.orange.opacity(0.85))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                    .help("常に許可のルールを確認する")
                }
                if !monitor.sessions.isEmpty {
                    Button {
                        uiState.isPinned = true
                        uiState.showingReport = true
                    } label: {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                    .help("使用状況レポートを開く")
                }
                Text("\(monitor.sessions.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .rollingNumber()
            }
            .padding(.horizontal, 16)
            .animation(Motion.quick, value: alwaysAllow.rules.count)
            .animation(Motion.quick, value: monitor.sessions.count)

            if monitor.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(monitor.sessions.enumerated()), id: \.element.id) { index, session in
                            Button {
                                uiState.isPinned = true
                                uiState.selectedSessionId = session.sessionId
                            } label: {
                                SessionRow(
                                    session: session,
                                    summary: summaries.summaries[session.sessionId],
                                    justFinished: alerts.recentlyFinished.contains { $0.sessionId == session.sessionId },
                                    showsCost: settings.showCostEstimates,
                                    onReveal: {
                                        TerminalLocator.reveal(
                                            pid: session.pid,
                                            title: summaries.summaries[session.sessionId]?.title
                                        )
                                    }
                                )
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.98))
                            // 増減はその行だけが動くようにして、一覧全体が
                            // 跳ねないようにする。
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .animation(Motion.navigate, value: monitor.sessions.map(\.id))
            }
        }
    }

    /// セッションがないときは、マークを置いて「動いていない」ことを見せる。
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 8)
            AgentMarkView(activity: .idle, size: 34, introduces: true)
                .opacity(0.35)
            Text("実行中のセッションはありません")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

/// 折りたたみ時の右ウィングに出るバッジ。承認・応答待ち・完了で色と字だけが
/// 変わる。
///
/// 明滅させるのは左ウィングのマーク側（CoreAnimation）。ここまで
/// SwiftUI で動かすと、待っているあいだずっと毎フレームのレイアウトが
/// 走ってしまう。
private struct WingBadge: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .symbolRenderingMode(.hierarchical)
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .rollingNumber()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.16)))
        .shadow(color: tint.opacity(0.35), radius: 4)
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let summary: SessionSummary?
    /// 直前に手が空いたばかりの行。どのセッションが終わったのかは行でしか
    /// 分からないので、ピルのバッジではなくここに出す。
    var justFinished: Bool = false
    var showsCost: Bool = true
    var onReveal: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                PulsingDot(isActive: session.isBusy, size: 7)

                Text(session.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if justFinished {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                        Text("完了")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(AgentBrand.accent.opacity(0.9))
                    .transition(.opacity)
                }

                if let activity = summary?.lastActivity {
                    Text(Self.elapsed(since: activity))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Button(action: onReveal) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.85))
                .help("このセッションのターミナルを前面に出す")

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .offset(x: hovering ? 2 : 0)
            }

            Text(summary?.title ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // タイトルは後から書き換わるので、差し替わったことが
                // 分かるようクロスフェードさせる。
                .id(summary?.title ?? "—")
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: summary?.title)

            HStack(spacing: 6) {
                if let summary {
                    metric("ctx", summary.contextTokens, tint: .cyan)
                    metric("out", summary.outputTokens, tint: .purple)
                    if showsCost {
                        Text(TokenPricing.format(summary.costUSD))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(AgentBrand.accent.opacity(0.9))
                            .rollingNumber()
                            .animation(Motion.quick, value: summary.costUSD)
                    }
                }
                Spacer(minLength: 2)
                if let model = summary?.shortModel {
                    Text(model)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.07))
                .overlay {
                    // 動作中の行だけ枠がうっすら灯る。
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            session.isBusy ? Color.green.opacity(0.28) : Color.clear,
                            lineWidth: 1
                        )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .animation(Motion.quick, value: session.isBusy)
        .animation(Motion.quick, value: justFinished)
        .onHover { hovering = $0 }
    }

    private func metric(_ label: String, _ value: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(Self.format(value))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint.opacity(0.9))
                .rollingNumber()
                .animation(Motion.quick, value: value)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    static func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    static func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(seconds, 0))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
