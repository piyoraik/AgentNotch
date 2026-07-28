import SwiftUI

/// The choices from `AskUserQuestion`, offered the way the terminal offers
/// them.
///
/// Without this the panel showed the tool's raw JSON and two buttons, so the
/// only way to pick an option was to walk to the terminal — which is the one
/// thing the notch exists to avoid.
struct ApprovalQuestionsView: View {
    let questions: [ApprovalQuestion]
    /// Question text → picked labels. Empty means unanswered.
    @Binding var picked: [String: [String]]
    /// Hands the whole card to the terminal. The panel can't take typing —
    /// `NotchWindow.canBecomeKey` is false so it never steals focus from the
    /// terminal — so "その他" is a handoff, not an input field.
    var onFreeform: () -> Void

    /// The question the user tapped open, when they went back to one. Otherwise
    /// `openQuestion` falls back to the first one still unanswered.
    @State private var opened: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(questions) { question in
                    if question.id == openQuestion {
                        expanded(question)
                    } else {
                        collapsed(question)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: maxBoxHeight)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(Motion.quick, value: openQuestion)
    }

    /// What the panel has left over for the options.
    ///
    /// A question card is the roomiest thing the panel draws: the usage strip is
    /// hidden while an approval is pending, and the "always allow" rules can't
    /// answer a question so those buttons are skipped too. The rest of the card
    /// — heading, tool badge, the two action buttons, the single passthrough row
    /// — plus the notch cutout off the top comes to about 200pt, so the box can
    /// have the remainder instead of the 230pt it was fixed at.
    ///
    /// Derived from the setting rather than hardcoded because `panelHeight` is
    /// adjustable: on a short panel a fixed tall box would push 回答を送る off
    /// the bottom, which is worse than scrolling.
    private var maxBoxHeight: CGFloat {
        max(200, CGFloat(AppSettings.shared.panelHeight) - 200)
    }

    /// Only one question shows its options at a time.
    ///
    /// All of them expanded overflowed by a wide margin: two questions of three
    /// options each came to roughly 570pt inside a 230pt box, so answering meant
    /// scrolling two and a half screens without ever seeing how many questions
    /// there were. One open at a time fits, and the folded rows still say what
    /// is outstanding and what was picked.
    private var openQuestion: String? {
        if let opened, questions.contains(where: { $0.id == opened }) { return opened }
        return questions.first { (picked[$0.id] ?? []).isEmpty }?.id ?? questions.last?.id
    }

    private func expanded(_ question: ApprovalQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(question)

            Text(question.question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                row(question: question, option: option)
            }

            // The CLI adds "Other" to every question of its own accord, so a
            // list that stops at the last option looks like it lost a choice.
            // Offering it where the terminal offers it is also where the user
            // finds out none of the options fit.
            freeformRow
        }
    }

    /// A question that isn't the one being answered: its heading, and either the
    /// answer it already carries or the fact that it is still waiting.
    private func collapsed(_ question: ApprovalQuestion) -> some View {
        let answer = (picked[question.id] ?? []).joined(separator: ", ")
        return Button {
            opened = question.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: answer.isEmpty ? "circle.dotted" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(answer.isEmpty ? .white.opacity(0.3) : AgentBrand.accent)

                VStack(alignment: .leading, spacing: 1) {
                    if !question.header.isEmpty {
                        Text(question.header)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text(answer.isEmpty ? question.question : answer)
                        .font(.system(size: 11, weight: answer.isEmpty ? .regular : .medium))
                        .foregroundStyle(.white.opacity(answer.isEmpty ? 0.5 : 0.85))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 選択肢と同じ列に置くが、選べるものには見せない。押すと状態が変わるのでは
    /// なく、この 1 件がターミナルに移る。寒色を外して地の白にしてあるのは、
    /// 「選ぶ」側の色（ミント）と役割が違うため。
    private var freeformRow: some View {
        Button(action: onFreeform) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))

                VStack(alignment: .leading, spacing: 1) {
                    Text("その他（自由に書く）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("この質問をターミナルに渡します")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("ノッチのパネルは文字入力を受け取れないため、ターミナルで答えます")
    }

    private func heading(_ question: ApprovalQuestion) -> some View {
        HStack(spacing: 6) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AgentBrand.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AgentBrand.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if question.multiSelect {
                Text("複数選択可")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
    }

    private func row(question: ApprovalQuestion, option: ApprovalQuestion.Option) -> some View {
        let selected = picked[question.id]?.contains(option.label) ?? false
        return Button {
            toggle(question: question, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // 単一選択は丸、複数選択は四角。押したあとに何が起きるかを、
                // 押す前の形で見せておく。
                Image(systemName: marker(multiSelect: question.multiSelect, selected: selected))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? AgentBrand.accent : .white.opacity(0.35))

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(selected ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // プレビューは AA の図で幅を食うので、選んだものだけ開く。
                    if selected, let preview = option.preview, !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentBrand.accent.opacity(selected ? 0.14 : 0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AgentBrand.accent.opacity(selected ? 0.5 : 0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func marker(multiSelect: Bool, selected: Bool) -> String {
        if multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(question: ApprovalQuestion, label: String) {
        var current = picked[question.id] ?? []
        guard question.multiSelect else {
            picked[question.id] = current == [label] ? [] : [label]
            // Answered, so hand the open slot back to whatever is still
            // outstanding. Clearing rather than naming the next one keeps
            // deselecting from skipping past this question.
            opened = nil
            return
        }
        if let index = current.firstIndex(of: label) {
            current.remove(at: index)
        } else {
            current.append(label)
        }
        picked[question.id] = current
    }
}
