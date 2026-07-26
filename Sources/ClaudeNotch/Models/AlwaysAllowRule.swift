import Foundation

/// A standing approval the user granted from the notch, so a matching request
/// is answered without asking again.
struct AlwaysAllowRule: Codable, Identifiable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable {
        /// Every call to the tool, whatever the input.
        case tool
        /// Only this exact input — the command line, path, or URL shown.
        case exact
        /// A rule string Claude Code proposed, e.g. `xcodegen generate *`.
        case pattern
    }

    let id: UUID
    let toolName: String
    let scope: Scope
    /// `nil` for `.tool`; the request's detail for `.exact`; the rule string
    /// for `.pattern`.
    let value: String?
    let createdAt: Date

    init(toolName: String, scope: Scope, value: String?, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.toolName = toolName
        self.scope = scope
        self.value = scope == .tool ? nil : value
        self.createdAt = createdAt
    }

    /// Shell metacharacters that let a second command ride along behind an
    /// approved prefix. `git *` must not clear `git status && rm -rf /`, so a
    /// pattern rule steps aside whenever the command chains.
    private static let chainingTokens = ["&&", "||", ";", "|", "`", "$(", "\n", ">", "<"]

    func matches(_ request: ApprovalRequest) -> Bool {
        guard request.toolName == toolName else { return false }

        switch scope {
        case .tool:
            return true

        case .exact:
            return request.detail == value

        case .pattern:
            guard let pattern = value else { return false }
            if isShellTool, Self.chainingTokens.contains(where: request.detail.contains) {
                return false
            }
            guard pattern.hasSuffix("*") else { return request.detail == pattern }
            return request.detail.hasPrefix(String(pattern.dropLast()))
        }
    }

    private var isShellTool: Bool {
        toolName == "Bash" || toolName == "BashOutput"
    }

    /// What the rule row and the button say it covers.
    var displayValue: String {
        switch scope {
        case .tool: return "入力を問わず"
        case .exact, .pattern: return value ?? ""
        }
    }
}
