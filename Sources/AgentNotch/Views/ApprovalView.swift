import SwiftUI

struct ApprovalView: View {
    let pending: ApprovalStore.Pending
    let remaining: Int
    var onDecision: (ApprovalDecision) -> Void
    var onAlwaysAllow: (AlwaysAllowRule) -> Void
    /// Non-nil when the requesting session's terminal can be brought forward.
    var onReveal: (() -> Void)?

    private var request: ApprovalRequest { pending.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                // 点滅させたいところだが、SwiftUI の繰り返しアニメーションは
                // パネル全体のレイアウトを毎フレーム走らせる。動きは
                // ノッチ側のマーク（CoreAnimation）に任せ、ここは静かな光に
                // とどめている。
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                    .shadow(color: .yellow.opacity(0.6), radius: 5)
                Text("承認が必要です")
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
            }
            .staggeredAppear(index: 0)
            .animation(Motion.quick, value: remaining)

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

                ApprovalDetailView(request: request)
            }
            .staggeredAppear(index: 1)

            HStack(spacing: 8) {
                actionButton("拒否", tint: .red) { onDecision(.deny) }
                actionButton("許可", tint: .green) { onDecision(.allow) }
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

    private func actionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        ApprovalActionButton(title: title, tint: tint, action: action)
    }
}

/// 許可 / 拒否。誤操作の代償が大きいので、ホバーで色が濃くなり
/// 押すと沈む、という手応えを付けている。
private struct ApprovalActionButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(tint.opacity(hovering ? 0.34 : 0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(tint.opacity(hovering ? 0.7 : 0.35), lineWidth: 1)
                )
                .foregroundStyle(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .shadow(color: tint.opacity(hovering ? 0.4 : 0), radius: 8)
        }
        .buttonStyle(PressableButtonStyle())
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}
