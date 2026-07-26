import SwiftUI

struct NotchContentView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var uiState: NotchUIState
    @ObservedObject var transcripts: TranscriptStore
    @ObservedObject var summaries: SummaryStore
    @ObservedObject var approvals: ApprovalStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var settings: AppSettings
    /// Width of the physical notch to leave uncovered; 0 on screens without one.
    let notchWidth: CGFloat
    let collapsedHeight: CGFloat

    private var busyCount: Int {
        monitor.sessions.filter(\.isBusy).count
    }

    private var showsUsage: Bool { settings.showUsageInNotch && settings.usageEnabled }

    private var selectedSession: ClaudeSession? {
        guard let id = uiState.selectedSessionId else { return nil }
        return monitor.sessions.first { $0.sessionId == id }
    }

    var body: some View {
        Group {
            if uiState.isExpanded {
                expandedView
            } else {
                collapsedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: uiState.isExpanded ? 22 : 10,
                bottomTrailingRadius: uiState.isExpanded ? 22 : 10,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
        )
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
        .animation(.easeInOut(duration: 0.2), value: uiState.isExpanded)
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
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(monitor.sessions.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
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
            Circle()
                .fill(busyCount > 0 ? Color.green : Color.white.opacity(0.35))
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(busyCount > 0 ? "busy" : "idle")
                .font(.system(size: compact ? 9 : 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Usage is the resting state here; a pending approval is urgent enough to
    /// take the slot until it is answered.
    private var rightWing: some View {
        HStack(spacing: 4) {
            if approvals.pending.isEmpty {
                if showsUsage {
                    UsageWingView(snapshot: usage.snapshot)
                } else {
                    busyIndicator(compact: false)
                }
            } else {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                Text("承認")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow)
            }
        }
    }

    // MARK: - Expanded

    private var expandedView: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: collapsedHeight + 6)

            if approvals.pending.isEmpty, settings.usageEnabled {
                UsageStripView(snapshot: usage.snapshot)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            if let pending = approvals.pending.first {
                ApprovalView(
                    pending: pending,
                    remaining: approvals.pending.count,
                    onDecision: { approvals.resolve(pending, with: $0) },
                    onReveal: monitor.sessions
                        .first { $0.sessionId == pending.request.sessionId }
                        .map { session in { TerminalLocator.reveal(pid: session.pid) } }
                )
            } else if let session = selectedSession {
                SessionDetailView(
                    session: session,
                    detail: transcripts.detail,
                    onBack: { uiState.selectedSessionId = nil }
                )
            } else {
                sessionList
            }
        }
        .padding(.bottom, 14)
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude Code Sessions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(monitor.sessions.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 16)

            if monitor.sessions.isEmpty {
                Text("実行中のセッションはありません")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(monitor.sessions) { session in
                            Button {
                                uiState.isPinned = true
                                uiState.selectedSessionId = session.sessionId
                            } label: {
                                SessionRow(
                                    session: session,
                                    summary: summaries.summaries[session.sessionId],
                                    onReveal: { TerminalLocator.reveal(pid: session.pid) }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let summary: SessionSummary?
    var onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.isBusy ? Color.green : Color.white.opacity(0.3))
                    .frame(width: 7, height: 7)

                Text(session.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 4)

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
                .buttonStyle(.plain)
                .help("このセッションのターミナルを前面に出す")

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Text(summary?.title ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let summary {
                    metric("ctx", summary.contextTokens, tint: .cyan)
                    metric("out", summary.outputTokens, tint: .purple)
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
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func metric(_ label: String, _ value: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(Self.format(value))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint.opacity(0.9))
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
