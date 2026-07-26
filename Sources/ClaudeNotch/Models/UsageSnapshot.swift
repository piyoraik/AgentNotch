import Foundation

/// One rate-limit window as Claude reports it: how much of the allowance is
/// spent, and when the window rolls over.
struct UsageWindow: Equatable {
    let percent: Int
    let resetsAt: Date?

    var fraction: Double { min(max(Double(percent) / 100, 0), 1) }

    /// Compact countdown to the reset — "2h13m", "45m", "4d3h".
    func resetCountdown(from now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return "まもなく" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

/// The 5-hour and weekly windows, i.e. what `/usage` prints in the CLI.
struct UsageSnapshot: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var fetchedAt: Date?
    /// Non-nil when the last fetch failed, so the UI can say so instead of
    /// passing stale numbers off as current.
    var failure: String?

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil }
}
