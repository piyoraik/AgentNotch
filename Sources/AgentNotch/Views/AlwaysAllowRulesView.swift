import SwiftUI

/// Lists the standing approvals so they stay visible and revocable. A rule the
/// user cannot find is a rule they cannot take back.
struct AlwaysAllowRulesView: View {
    @ObservedObject var store: AlwaysAllowStore
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if store.rules.isEmpty {
                Text("常に許可のルールはありません")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.rules) { rule in
                            row(rule)
                        }
                    }
                }

                Button {
                    store.removeAll()
                } label: {
                    Text("すべて削除")
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Text("常に許可")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Text("\(store.rules.count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func row(_ rule: AlwaysAllowRule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(rule.toolName)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.12))
                        .foregroundStyle(.white.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    switch rule.scope {
                    case .tool:
                        Text("入力を問わず")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.9))
                    case .pattern:
                        Text("パターン")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.cyan.opacity(0.9))
                    case .exact:
                        Text("完全一致")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                if let value = rule.value {
                    Text(value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            Button {
                store.remove(rule)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("このルールを削除")
        }
        .padding(8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
