import SwiftUI

struct ApprovalView: View {
    let pending: ApprovalStore.Pending
    let remaining: Int
    var onDecision: (ApprovalDecision) -> Void
    /// Non-nil when the requesting session's terminal can be brought forward.
    var onReveal: (() -> Void)?

    private var request: ApprovalRequest { pending.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                Text("承認が必要です")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if remaining > 1 {
                    Text("他 \(remaining - 1) 件")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

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

                ScrollView {
                    Text(request.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                actionButton("拒否", tint: .red) { onDecision(.deny) }
                actionButton("許可", tint: .green) { onDecision(.allow) }
            }

            Button {
                onDecision(.passthrough)
            } label: {
                Text("ターミナルで決める")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
    }

    private func actionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(tint.opacity(0.22))
                .foregroundStyle(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
