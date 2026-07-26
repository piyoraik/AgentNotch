import SwiftUI

struct SessionDetailView: View {
    let session: ClaudeSession
    let detail: SessionDetail?
    var showsCost: Bool = true
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let detail {
                if showsCost {
                    costBar(detail)
                }
                tokenGrid(detail.tokens)
                if !detail.memories.isEmpty {
                    memories(detail.memories)
                }
                Divider().overlay(Color.white.opacity(0.12))
                transcript(detail.messages)
            } else {
                loading
            }
        }
        .padding(.horizontal, 14)
        .animation(Motion.navigate, value: detail == nil)
    }

    /// 推定コストはトークン数より粗い数字なので、グリッドに混ぜず
    /// 一段上に置いて「別物」だと分かるようにしている。
    private func costBar(_ detail: SessionDetail) -> some View {
        HStack(spacing: 8) {
            Text("推定コスト")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))

            Text(TokenPricing.format(detail.costUSD))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AgentBrand.accent)
                .rollingNumber()
                .animation(Motion.quick, value: detail.costUSD)

            if detail.tokensByModel.count > 1 {
                Text("\(detail.tokensByModel.count) モデル")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AgentBrand.accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .staggeredAppear(index: 0)
    }

    /// 読み込み中はマークを回しておく。JSONL が大きいと数百 ms 空くので、
    /// 固まったように見えないようにする。
    private var loading: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 12)
            ClaudeMarkView(activity: .busy, size: 28)
            Text("トランスクリプトを読み込み中…")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.85))

                Text(detail?.title ?? session.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Button {
                    TerminalLocator.reveal(pid: session.pid, title: detail?.title)
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.85))
                .help("このセッションのターミナルを前面に出す")

                HStack(spacing: 4) {
                    PulsingDot(isActive: session.isBusy, size: 5)
                    Text(session.isBusy ? "busy" : "idle")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(session.isBusy ? Color.green.opacity(0.2) : Color.white.opacity(0.12))
                .foregroundStyle(session.isBusy ? Color.green : Color.white.opacity(0.6))
                .clipShape(Capsule())
                .animation(Motion.quick, value: session.isBusy)
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
            tokenCell("Context", tokens.context, tint: .cyan).staggeredAppear(index: 0)
            tokenCell("Output", tokens.output, tint: .purple).staggeredAppear(index: 1)
            tokenCell("Cache read", tokens.cacheRead, tint: .green).staggeredAppear(index: 2)
            tokenCell("Cache write", tokens.cacheWrite, tint: .orange).staggeredAppear(index: 3)
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
                .rollingNumber()
                .animation(Motion.quick, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// メモリはトークンと同じ「このセッションの持ち物」なので、発言の流れの
    /// 上に置く。参照が無いセッションでは丸ごと出さない。
    private func memories(_ memories: [MemoryReference]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("参照したメモリ")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))

            ForEach(memories) { memory in
                MemoryRow(memory: memory)
            }
        }
    }

    private func transcript(_ messages: [TranscriptMessage]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .staggeredAppear(index: min(index, 6), offset: 12)
                            // 追記は下から積み上がる。ポーリングで一気に
                            // 差し込まれても流れが読めるようにする。
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 8)
                .animation(Motion.navigate, value: messages.count)
            }
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
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

/// 行そのものを押して本体を開く。「開く」ボタンを別に置くと、狭いパネルで
/// 当たり判定が二つに割れる。
private struct MemoryRow: View {
    let memory: MemoryReference

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: memory.path))
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: memory.origin == .recalled ? "brain" : "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(AgentBrand.accent.opacity(memory.origin == .recalled ? 0.8 : 0.45))
                    .padding(.top, 1)
                    .help(memory.origin == .recalled ? "リコールされた" : "このセッションが開いた")

                VStack(alignment: .leading, spacing: 1) {
                    Text(memory.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)

                    if let summary = memory.summary {
                        Text(summary)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .disabled(!memory.exists)
        .opacity(memory.exists ? 1 : 0.5)
        .help(memory.exists ? memory.path : "\(memory.path)（削除済み）")
    }
}

private struct MessageBubble: View {
    let message: TranscriptMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if message.role != .user {
                    ClaudeMarkView(activity: .idle, size: 9)
                }
                Text(message.role == .user ? "You" : "Claude")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(message.role == .user
                                     ? Color.cyan.opacity(0.8)
                                     : AgentBrand.accent.opacity(0.95))
            }

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
