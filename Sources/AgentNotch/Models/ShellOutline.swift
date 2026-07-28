import Foundation

/// A reading aid for `Bash` requests: the programs a command line will run, and
/// the script bodies it carries inline.
///
/// A command that feeds a here-document into an interpreter says almost nothing
/// in its first line, and forty lines of Python push the pipeline it belongs to
/// off a 440pt panel. This pulls the parts away from each other so the decision
/// can be made from "what runs" instead of from parsing quoting by eye.
///
/// Deliberately approximate, and never load-bearing. `AlwaysAllowRule` matches
/// on the raw command text and the verbatim command stays on screen underneath,
/// so a bad split shows a confusing chip — it can never widen what a rule
/// allows. Do not reuse this for matching.
struct ShellOutline: Sendable, Equatable {
    struct Script: Sendable, Equatable, Identifiable {
        /// The program on the line that opened the here-document, when it names
        /// one — `python3` for `python3 - <<EOF`.
        let interpreter: String?
        let body: String

        var lineCount: Int {
            body.split(separator: "\n", omittingEmptySubsequences: false).count
        }

        var id: String { (interpreter ?? "") + "\u{1}" + body }
    }

    /// Programs in the order they first appear, each listed once.
    let programs: [String]
    /// The command with here-document bodies lifted out, so the pipeline stays
    /// readable. The line that opens each here-document is kept.
    let command: String
    let scripts: [Script]

    init(command raw: String) {
        let lifted = ShellOutline.liftHeredocs(from: raw)
        command = lifted.command
        scripts = lifted.scripts
        programs = ShellOutline.programs(in: lifted.command)
    }

    // MARK: - Here-documents

    private struct Marker {
        let delimiter: String
        /// `<<-` lets the closing delimiter be indented with tabs.
        let dashed: Bool
    }

    private static func liftHeredocs(from raw: String) -> (command: String, scripts: [Script]) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var scripts: [Script] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            kept.append(line)
            index += 1

            guard let marker = heredocMarker(in: line) else { continue }

            var body: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                index += 1
                var closing = Substring(candidate)
                if marker.dashed { closing = closing.drop(while: { $0 == "\t" }) }
                if closing.hasSuffix(" ") || closing.hasSuffix("\t") {
                    closing = Substring(closing.trimmingCharacters(in: .whitespaces))
                }
                if closing == marker.delimiter { break }
                body.append(candidate)
            }

            scripts.append(
                Script(interpreter: firstProgram(in: line), body: body.joined(separator: "\n"))
            )
        }

        return (kept.joined(separator: "\n"), scripts)
    }

    /// Finds a `<<DELIM` opener outside quotes. `<<<` is a here-string and takes
    /// no body, so it is skipped rather than mistaken for one.
    private static func heredocMarker(in line: String) -> Marker? {
        let chars = Array(line)
        var quote: Character?
        var index = 0

        while index < chars.count {
            let character = chars[index]

            if let open = quote {
                if character == open { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index += 1
                continue
            }
            guard character == "<", index + 1 < chars.count, chars[index + 1] == "<" else {
                index += 1
                continue
            }

            var cursor = index + 2
            var dashed = false
            if cursor < chars.count, chars[cursor] == "-" {
                dashed = true
                cursor += 1
            }
            if cursor < chars.count, chars[cursor] == "<" {
                index = cursor + 1
                continue
            }
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }

            var quoted: Character?
            if cursor < chars.count, chars[cursor] == "'" || chars[cursor] == "\"" {
                quoted = chars[cursor]
                cursor += 1
            }

            var word = ""
            while cursor < chars.count {
                let next = chars[cursor]
                if let close = quoted {
                    if next == close { break }
                } else if !(next.isLetter || next.isNumber || next == "_") {
                    break
                }
                word.append(next)
                cursor += 1
            }

            if !word.isEmpty { return Marker(delimiter: word, dashed: dashed) }
            index = cursor
        }

        return nil
    }

    // MARK: - Programs

    private static func programs(in command: String) -> [String] {
        var found: [String] = []
        for segment in segments(of: command) {
            guard let program = firstProgram(in: segment), !found.contains(program) else { continue }
            found.append(program)
        }
        return found
    }

    /// Splits on the tokens that start a new command, ignoring any inside
    /// quotes. The same set `AlwaysAllowRule.chainingTokens` refuses to match
    /// across, for the same reason: each one runs something else.
    private static func segments(of command: String) -> [String] {
        let chars = Array(command)
        var out: [String] = []
        var current = ""
        var quote: Character?
        var index = 0

        while index < chars.count {
            let character = chars[index]

            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                index += 1
                continue
            }
            if character == "\n" || character == ";" || character == "|" || character == "&" {
                out.append(current)
                current = ""
                index += 1
                // `&&` and `||` are two characters; a lone `&` backgrounds.
                if index < chars.count, chars[index] == character { index += 1 }
                continue
            }

            current.append(character)
            index += 1
        }

        out.append(current)
        return out
    }

    /// The program a segment runs: its first bare word, skipping the
    /// `FOO=bar cmd` assignments a shell allows in front of one.
    private static func firstProgram(in segment: String) -> String? {
        for token in segment.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let word = String(token)
            if word.contains("=") { continue }

            let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: "()${}\"'`!"))
            if cleaned.isEmpty || cleaned.hasPrefix("-") { continue }

            return (cleaned as NSString).lastPathComponent
        }
        return nil
    }
}
