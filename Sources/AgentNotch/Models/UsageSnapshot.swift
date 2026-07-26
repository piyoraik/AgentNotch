import Foundation

/// One rate-limit window as Claude reports it: how much of the allowance is
/// spent, and when the window rolls over.
struct UsageWindow: Equatable, Codable {
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
///
/// `Codable` over the three data fields only: the numbers are cached to disk so
/// a relaunch — or a rate-limited endpoint — still has something to show, while
/// the transient status is rebuilt each run.
struct UsageSnapshot: Equatable, Codable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    /// When these numbers actually came off the endpoint, as opposed to when we
    /// last published a status change.
    var measuredAt: Date?
    var fetchedAt: Date?
    /// Non-nil when the last fetch failed, so the UI can say so instead of
    /// passing stale numbers off as current.
    var failure: String?

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

    /// Numbers we are still showing while something is wrong with fetching.
    var isStale: Bool { failure != nil && !isEmpty }

    var measuredAtText: String? {
        guard let measuredAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: measuredAt)
    }

    private enum CodingKeys: String, CodingKey {
        case fiveHour, sevenDay, measuredAt
    }
}
