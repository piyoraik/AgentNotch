import SwiftUI

/// The "don't ask again" choices, mirroring what the terminal prompt offers.
///
/// Claude Code ships its own suggestions in `permission_suggestions`
/// (`xcodegen generate *` and the like); those are offered first because they
/// are scoped the way the CLI itself would scope them.
struct ApprovalAlwaysAllowButtons: View {
    let request: ApprovalRequest
    var onAlwaysAllow: (AlwaysAllowRule) -> Void
    var onPassthrough: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // A standing rule can't answer a question — it would return "allow"
            // with nothing in it, which Claude Code reads as no decision and
            // asks the terminal instead. `ApprovalStore` skips its rules for
            // these tools for the same reason; offering the buttons here would
            // just be a switch that does nothing.
            if !request.requiresInteraction {
                ForEach(request.suggestedRules, id: \.self) { rule in
                    button(
                        title: "今後 \(rule) は確認しない",
                        subtitle: "Claude Code の推奨する範囲",
                        icon: "checkmark.shield.fill",
                        tint: .cyan,
                        monospacedTitle: true
                    ) {
                        onAlwaysAllow(
                            AlwaysAllowRule(toolName: request.toolName, scope: .pattern, value: rule)
                        )
                    }
                }

                if request.suggestedRules.isEmpty, !request.detail.isEmpty {
                    button(
                        title: "この内容を常に許可",
                        subtitle: "入力が完全に一致したときだけ",
                        icon: "checkmark.shield",
                        tint: .cyan
                    ) {
                        onAlwaysAllow(
                            AlwaysAllowRule(toolName: request.toolName, scope: .exact, value: request.detail)
                        )
                    }
                }

                button(
                    title: "\(request.toolName) を常に許可",
                    subtitle: "入力を問わず、以後すべて通す",
                    icon: "exclamationmark.triangle",
                    tint: .orange
                ) {
                    onAlwaysAllow(
                        AlwaysAllowRule(toolName: request.toolName, scope: .tool, value: nil)
                    )
                }
            }

            Button(action: onPassthrough) {
                VStack(spacing: 1) {
                    Text(passthroughLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    // Measured: a subagent's request that goes unanswered runs
                    // anyway. The bridge fails open after 120s, the terminal
                    // asks nothing, and Claude Code applies its own default —
                    // in the observed case that meant the tool went ahead. The
                    // old label promised a prompt that never comes.
                    if request.isSubagent {
                        Text("Claude Code の既定に委ねます")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var passthroughLabel: String {
        if request.isSubagent { return "ここでは決めない" }
        if request.requiresInteraction { return "ターミナルで答える" }
        return "ターミナルで決める"
    }

    /// Each choice states its own consequence: the tool-wide one is easy to
    /// press by reflex and hard to notice afterwards.
    private func button(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        monospacedTitle: Bool = false,
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
                        .font(.system(size: 12, weight: .medium, design: monospacedTitle ? .monospaced : .default))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
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
        .buttonStyle(.plain)
    }
}
