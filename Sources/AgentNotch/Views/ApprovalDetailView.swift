import SwiftUI

/// Renders what a request will actually do. A path alone doesn't tell the user
/// what changes, so edits arrive here as a diff rather than a file name.
struct ApprovalDetailView: View {
    let request: ApprovalRequest

    /// Long bodies are truncated rather than scrolled forever; the panel is
    /// 440pt wide and a decision shouldn't require reading 500 lines.
    private let lineLimit = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                switch request.body {
                case .command(let command):
                    shell(command)

                case .diff(let old, let new):
                    diff(old: old, new: new)

                case .text(let text):
                    monospaced(text, tint: .white.opacity(0.85))

                // Questions are pickable, so `ApprovalView` sends them to
                // `ApprovalQuestionsView` instead. Listing them here only keeps
                // the switch honest.
                case .questions(let asked):
                    monospaced(asked.map(\.question).joined(separator: "\n"), tint: .white.opacity(0.85))

                case .none:
                    Text("この操作に追加の入力はありません")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 190)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// A shell command, with what it runs pulled out in front of it.
    ///
    /// The chips and the folded script are additive: the command itself is still
    /// printed verbatim, because that is what the decision applies to and what a
    /// standing rule would match on.
    @ViewBuilder
    private func shell(_ command: String) -> some View {
        let outline = ShellOutline(command: command)
        VStack(alignment: .leading, spacing: 6) {
            // A lone `git status` explains itself; the summary is for the ones
            // that chain, pipe, or carry a script.
            if outline.programs.count > 1 || !outline.scripts.isEmpty {
                programs(outline.programs)
            }

            monospaced(outline.command, tint: .white.opacity(0.9))

            ForEach(outline.scripts) { script in
                EmbeddedScriptView(script: script, lineLimit: lineLimit)
            }
        }
    }

    /// The programs the command line will run, in order.
    private func programs(_ names: [String]) -> some View {
        let shown = names.prefix(5)
        return HStack(spacing: 4) {
            ForEach(Array(shown), id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if names.count > shown.count {
                Text("+\(names.count - shown.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .help("このコマンドが実行するプログラム")
    }

    private func monospaced(_ text: String, tint: Color) -> some View {
        let lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false))
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.prefix(lineLimit).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            overflowNote(total: lines.count)
        }
    }

    private func diff(old: String, new: String) -> some View {
        let change = LineDiff(old: old, new: new)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(change.removed.prefix(lineLimit / 2).enumerated()), id: \.offset) { _, line in
                diffLine("-", line, tint: .red)
            }
            ForEach(Array(change.added.prefix(lineLimit / 2).enumerated()), id: \.offset) { _, line in
                diffLine("+", line, tint: .green)
            }
            if change.removed.isEmpty, change.added.isEmpty {
                Text("内容に変化はありません")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            overflowNote(total: max(change.removed.count, change.added.count), limit: lineLimit / 2)
        }
    }

    private func diffLine(_ marker: String, _ line: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
            Text(line.isEmpty ? " " : line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    @ViewBuilder
    private func overflowNote(total: Int, limit: Int? = nil) -> some View {
        let cap = limit ?? lineLimit
        if total > cap {
            Text("… 他 \(total - cap) 行")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 2)
        }
    }
}

/// A here-document body, shown apart from the command that carries it.
///
/// Short ones open by themselves — folding three lines of Python only hides
/// them. Long ones start closed so the pipeline above stays visible; the point
/// of splitting them out is that the command line was being buried.
private struct EmbeddedScriptView: View {
    let script: ShellOutline.Script
    let lineLimit: Int

    @State private var expanded: Bool

    /// Above this many lines the body is folded on arrival.
    private static let foldOver = 12

    init(script: ShellOutline.Script, lineLimit: Int) {
        self.script = script
        self.lineLimit = lineLimit
        _expanded = State(initialValue: script.lineCount <= Self.foldOver)
    }

    private var title: String {
        let count = script.lineCount
        guard let interpreter = script.interpreter else { return "埋め込みスクリプト \(count) 行" }
        return "\(interpreter) に渡すスクリプト \(count) 行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.55))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                let lines = script.body.split(separator: "\n", omittingEmptySubsequences: false)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.prefix(lineLimit).enumerated()), id: \.offset) { _, line in
                        Text(String(line).isEmpty ? " " : String(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if lines.count > lineLimit {
                        Text("… 他 \(lines.count - lineLimit) 行")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.leading, 10)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Trims the lines an edit leaves untouched so only the change is shown.
/// A full LCS would be nicer, but Claude Code's `old_string`/`new_string`
/// pairs already share their context at the head and tail.
private struct LineDiff {
    let removed: [String]
    let added: [String]

    init(old: String, new: String) {
        var oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        while let a = oldLines.first, let b = newLines.first, a == b {
            oldLines.removeFirst()
            newLines.removeFirst()
        }
        while let a = oldLines.last, let b = newLines.last, a == b {
            oldLines.removeLast()
            newLines.removeLast()
        }

        removed = oldLines
        added = newLines
    }
}
