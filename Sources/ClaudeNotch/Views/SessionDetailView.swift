import SwiftUI

struct SessionDetailView: View {
    let session: ClaudeSession
    let detail: SessionDetail?
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let detail {
                tokenGrid(detail.tokens)
                Divider().overlay(Color.white.opacity(0.12))
                transcript(detail.messages)
            } else {
                Text("トランスクリプトを読み込み中…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
        }
        .padding(.horizontal, 14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)

                Text(detail?.title ?? session.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Button {
                    TerminalLocator.reveal(pid: session.pid)
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("このセッションのターミナルを前面に出す")

                Text(session.isBusy ? "busy" : "idle")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(session.isBusy ? Color.green.opacity(0.2) : Color.white.opacity(0.12))
                    .foregroundStyle(session.isBusy ? Color.green : Color.white.opacity(0.6))
                    .clipShape(Capsule())
            }

            Text(session.cwd)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.head)

            if let model = detail?.model {
                Text(model)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func tokenGrid(_ tokens: TokenStats) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
            tokenCell("Context", tokens.context, tint: .cyan)
            tokenCell("Output", tokens.output, tint: .purple)
            tokenCell("Cache read", tokens.cacheRead, tint: .green)
            tokenCell("Cache write", tokens.cacheWrite, tint: .orange)
        }
    }

    private func tokenCell(_ label: String, _ value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(format(value))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func transcript(_ messages: [TranscriptMessage]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct MessageBubble: View {
    let message: TranscriptMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .user ? "You" : "Claude")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(message.role == .user ? Color.cyan.opacity(0.8) : Color.orange.opacity(0.8))

            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !message.toolNames.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(message.toolNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.1))
                            .foregroundStyle(.white.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
