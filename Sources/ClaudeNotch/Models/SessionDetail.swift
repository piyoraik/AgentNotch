import Foundation

struct TokenStats: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Approximate size of the live context window: the prompt side of the
    /// most recent assistant turn.
    var context = 0

    var totalBilledInput: Int { input + cacheWrite }
}

struct TranscriptMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let toolNames: [String]
    let timestamp: Date?
}

struct SessionDetail: Equatable {
    var title: String?
    var model: String?
    var tokens = TokenStats()
    /// Token counts split by the model that produced them. A session that
    /// switched models has to price each stretch at its own rate, so the
    /// aggregate above can't be used for cost on its own.
    var tokensByModel: [String: TokenStats] = [:]
    var messages: [TranscriptMessage] = []

    /// Estimated equivalent API cost. Unrecognised models contribute nothing
    /// rather than dropping the whole figure — see `TokenPricing`.
    var costUSD: Double {
        tokensByModel.reduce(0) { total, entry in
            total + (TokenPricing.cost(of: entry.value, model: entry.key) ?? 0)
        }
    }
}

/// The cheap slice of a transcript needed to render a list row, so the
/// overview doesn't require opening each session.
struct SessionSummary: Equatable {
    var title: String?
    var model: String?
    var tokens = TokenStats()
    /// Accumulated per message while parsing, so a mid-session model switch is
    /// priced correctly without keeping the full per-model breakdown around.
    var costUSD: Double = 0
    var lastActivity: Date?

    var contextTokens: Int { tokens.context }
    var outputTokens: Int { tokens.output }

    /// "claude-sonnet-5" reads as noise in a narrow row; "sonnet-5" doesn't.
    var shortModel: String? {
        model?.replacingOccurrences(of: "claude-", with: "")
    }

    static func abbreviate(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}
