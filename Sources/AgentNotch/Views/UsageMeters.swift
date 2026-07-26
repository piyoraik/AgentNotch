import SwiftUI

enum UsageTint {
    static func color(for percent: Int) -> Color {
        switch percent {
        case ..<60: return Color.green
        case ..<85: return Color.yellow
        default: return Color.red
        }
    }
}

/// The always-visible pair of meters in the collapsed notch. Two stacked rows
/// fit the notch height where a single line would not fit the wing width.
struct UsageWingView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            row("5h", snapshot.fiveHour)
            row("7d", snapshot.sevenDay)
        }
        // Held-over numbers read dimmer than live ones, so a stalled fetch
        // doesn't quietly pass as current.
        .opacity(snapshot.isStale ? 0.5 : 1)
    }

    /// The wing width is user-tunable down to 60pt, so shed the bar and then
    /// the label rather than clipping.
    private func row(_ label: String, _ window: UsageWindow?) -> some View {
        ViewThatFits(in: .horizontal) {
            meter(label, window, showsBar: true)
            meter(label, window, showsBar: false)
            percent(window)
        }
    }

    private func meter(_ label: String, _ window: UsageWindow?, showsBar: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize()

            if showsBar {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 22, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint(for: window).opacity(0.9))
                            .frame(width: 22 * (window?.fraction ?? 0), height: 3)
                            // 使用量は数分おきに数 % ずつ動く。数字だけ
                            // 飛ぶと見落とすので、バーを伸ばして見せる。
                            .animation(.spring(response: 0.6, dampingFraction: 0.85),
                                       value: window?.fraction ?? 0)
                    }
            }

            percent(window)
        }
    }

    private func percent(_ window: UsageWindow?) -> some View {
        Text(window.map { "\($0.percent)%" } ?? "--")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .rollingNumber()
            .lineLimit(1)
            .foregroundStyle(window == nil ? .white.opacity(0.35) : tint(for: window).opacity(0.95))
            // Wide enough for "100%", so a maxed-out window doesn't wrap.
            .frame(width: 31, alignment: .trailing)
            .animation(Motion.quick, value: window?.percent)
    }

    private func tint(for window: UsageWindow?) -> Color {
        window.map { UsageTint.color(for: $0.percent) } ?? Color.white.opacity(0.3)
    }
}

/// The detailed version shown once the panel is open: same numbers plus how
/// long until each window resets.
struct UsageStripView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 8) {
            card("5時間", snapshot.fiveHour)
            card("週間", snapshot.sevenDay)
        }
    }

    /// Kept-but-stale numbers say when they were read, so "97%" from twenty
    /// minutes ago is never mistaken for the current figure.
    private func status(for window: UsageWindow?) -> String {
        if let failure = snapshot.failure {
            guard window != nil, let measured = snapshot.measuredAtText else { return failure }
            return "\(measured) 時点 · \(failure)"
        }
        return window?.resetCountdown().map { "\($0)後にリセット" } ?? " "
    }

    private func card(_ label: String, _ window: UsageWindow?) -> some View {
        let tint = window.map { UsageTint.color(for: $0.percent) } ?? Color.white.opacity(0.3)
        // 上限が近いときだけバーに光を走らせる。常時光らせると
        // ノッチが賑やかになりすぎて、警告として効かなくなる。
        let urgent = (window?.percent ?? 0) >= 85

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 2)
                Text(window.map { "\($0.percent)%" } ?? "--")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .rollingNumber()
                    .foregroundStyle(window == nil ? .white.opacity(0.35) : tint)
                    .animation(Motion.quick, value: window?.percent)
            }

            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(tint.opacity(0.9))
                            .frame(width: proxy.size.width * (window?.fraction ?? 0))
                            .shadow(color: tint.opacity(urgent ? 0.6 : 0), radius: 4)
                            .animation(.spring(response: 0.6, dampingFraction: 0.85),
                                       value: window?.fraction ?? 0)
                    }
                }
                .clipShape(Capsule())

            // Doubles as the status line: the reason a fetch is not landing
            // goes here rather than floating over the card.
            Text(status(for: window))
                .font(.system(size: 9, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(snapshot.failure != nil
                                 ? .orange.opacity(0.75)
                                 : .white.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
