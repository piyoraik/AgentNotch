import SwiftUI

struct ApprovalView: View {
    let pending: ApprovalStore.Pending
    let remaining: Int
    var onDecision: (ApprovalDecision) -> Void
    var onAlwaysAllow: (AlwaysAllowRule) -> Void
    /// Non-nil when the requesting session's terminal can be brought forward.
    var onReveal: (() -> Void)?

    private var request: ApprovalRequest { pending.request }

    /// Ticks once a second so the countdown moves. Not an animation: the panel
    /// is only on screen while something is pending, and one layout pass per
    /// second is nothing like the per-frame cost `repeatForever` would bring.
    @State private var now = Date()
    private static let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Question text → picked labels, for `AskUserQuestion`. Reset per request
    /// because the card carries `.id(pending.id)`.
    @State private var picked: [String: [String]] = [:]

    private var questions: [ApprovalQuestion] { request.questions }
    private var isAnswered: Bool {
        questions.allSatisfy { !(picked[$0.id] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                // 点滅させたいところだが、SwiftUI の繰り返しアニメーションは
                // パネル全体のレイアウトを毎フレーム走らせる。動きは
                // ノッチ側のマーク（CoreAnimation）に任せ、ここは静かな光に
                // とどめている。
                Image(systemName: questions.isEmpty ? "exclamationmark.shield.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                    .shadow(color: .yellow.opacity(0.6), radius: 5)
                Text(questions.isEmpty ? "承認が必要です" : "回答を待っています")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if remaining > 1 {
                    Text("他 \(remaining - 1) 件")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .rollingNumber()
                        .transition(.scale.combined(with: .opacity))
                }
                countdown
            }
            .staggeredAppear(index: 0)
            .animation(Motion.quick, value: remaining)
            .onReceive(Self.tick) { now = $0 }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(request.toolName)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.18))
                        .foregroundStyle(.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    Text(request.projectName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)

                    if let agentType = request.agentType {
                        origin(agentType)
                    }

                    Spacer(minLength: 4)

                    if let onReveal {
                        Button(action: onReveal) {
                            Image(systemName: "terminal")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("要求元のターミナルを前面に出す")
                    }
                }

                if let headline = request.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if questions.isEmpty {
                    ApprovalDetailView(request: request)
                } else {
                    ApprovalQuestionsView(
                        questions: questions,
                        picked: $picked,
                        onFreeform: { onDecision(.passthrough) }
                    )
                }
            }
            .staggeredAppear(index: 1)

            HStack(spacing: 8) {
                actionButton("拒否", tint: .red) { onDecision(.deny) }
                if questions.isEmpty {
                    actionButton("許可", tint: .green) { onDecision(request.allowDecision) }
                } else {
                    // 未選択のまま送ると「回答しなかった」として渡ってしまう。
                    // 送れないことを、押せない形で見せておく。
                    actionButton("回答を送る", tint: .green, enabled: isAnswered) {
                        onDecision(request.answerDecision(picked))
                    }
                }
            }
            .staggeredAppear(index: 2)

            ApprovalAlwaysAllowButtons(
                request: request,
                onAlwaysAllow: onAlwaysAllow,
                onPassthrough: { onDecision(.passthrough) }
            )
            .staggeredAppear(index: 3)
        }
        .padding(.horizontal, 14)
    }

    /// Time left before the panel answers on the user's behalf.
    ///
    /// Shown because the deadline is otherwise invisible, and it is not a
    /// harmless one: left alone, a permission is denied at 0:00 rather than
    /// waiting for a terminal prompt that never comes.
    private var countdown: some View {
        let left = Int(request.secondsLeft(asOf: now).rounded())
        let urgent = left <= 20
        return Text(String(format: "%d:%02d", left / 60, left % 60))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(urgent ? .yellow : .white.opacity(0.4))
            .help(
                request.requiresInteraction
                    ? "0:00 でターミナルに渡します"
                    : "0:00 で拒否を返します。答えないまま通ることはありません"
            )
    }

    /// Marks a request a subagent made, which is why the terminal is showing no
    /// prompt of its own and why the session still looks busy behind it.
    private func origin(_ agentType: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 8))
            Text(agentType)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help("サブエージェントからの要求です。親セッションはこの間も動き続けます")
    }

    /// The standing-approval buttons carry their own consequence as a subtitle:
    /// the tool-wide one is easy to press by reflex and hard to undo.
    private func alwaysButton(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .hoverLift()
    }

    private func actionButton(
        _ title: String,
        tint: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        ApprovalActionButton(title: title, tint: tint, enabled: enabled, action: action)
    }
}

/// 許可 / 拒否。誤操作の代償が大きいので、ホバーで色が濃くなり
/// 押すと沈む、という手応えを付けている。
private struct ApprovalActionButton: View {
    let title: String
    let tint: Color
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    /// 効かないボタンにホバーの手応えを付けると、押せるのに反応しないように
    /// 見える。無効なあいだは色も動きも引っ込める。
    private var lit: Bool { enabled && hovering }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(tint.opacity(enabled ? (hovering ? 0.34 : 0.22) : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(tint.opacity(enabled ? (hovering ? 0.7 : 0.35) : 0.15), lineWidth: 1)
                )
                .foregroundStyle(tint.opacity(enabled ? 1 : 0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .shadow(color: tint.opacity(lit ? 0.4 : 0), radius: 8)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .scaleEffect(lit ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: lit)
        .onHover { hovering = $0 }
    }
}
