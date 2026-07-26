import SwiftUI

/// A session waiting on something the notch can't answer.
///
/// Deliberately not shaped like the approval panel: there are no allow/deny
/// buttons because the `Notification` hook takes no decision back. The only
/// useful action is getting to the terminal, so that is the only button.
struct NoticeBanner: View {
    let notice: AgentNotice
    let onReveal: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AgentBrand.amber)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.projectName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(notice.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onReveal {
                Button(action: onReveal) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.85))
                .help("このセッションのターミナルを前面に出す")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.85))
            .help("この知らせを閉じる")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AgentBrand.amber.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AgentBrand.amber.opacity(0.35), lineWidth: 1)
                }
        }
    }
}
