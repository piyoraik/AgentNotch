import Combine
import Foundation

/// Polls the OAuth usage endpoint the CLI's `/usage` command reads, so the
/// notch can show the 5-hour and weekly rate-limit windows at a glance.
///
/// `@unchecked Sendable` because URLSession delivers on a background queue;
/// every mutation below is hopped onto main first.
final class UsageStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var snapshot = UsageSnapshot()

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The endpoint is shared with the CLI and rate-limited, so never poll
    /// faster than this no matter what the settings say.
    private static let minimumInterval: TimeInterval = 60
    /// Ceiling for the 429 backoff, so a long outage still recovers on its own.
    private static let maximumBackoff: TimeInterval = 30 * 60

    private let settings: AppSettings
    private let cache: UserDefaults
    private var timer: Timer?
    private var isFetching = false
    private var lastAttempt: Date?
    /// Set while we are backing off after a 429; ticks that land inside it are
    /// skipped rather than queued up.
    private var retryAfter: Date?
    private var consecutiveRejections = 0
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings = .shared, cache: UserDefaults = .standard) {
        self.settings = settings
        self.cache = cache

        // Numbers survive a relaunch, so a restart neither shows "--" nor
        // spends a request the cached value could have answered.
        if let cached = loadCache() {
            snapshot = cached
            lastAttempt = cached.measuredAt
        }
    }

    /// The endpoint answers 429 well before you'd expect for a metadata read,
    /// so the interval is user-tunable but defaults to a quarter of an hour.
    func start() {
        settings.$usageEnabled
            .combineLatest(settings.$usageRefreshInterval)
            .removeDuplicates { $0 == $1 }
            // Dragging the interval slider walks through every step in between;
            // without this each one would rebuild the timer and fire a request.
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] enabled, interval in
                self?.reschedule(enabled: enabled, interval: interval)
            }
            .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }

    private func reschedule(enabled: Bool, interval: TimeInterval) {
        timer?.invalidate()
        timer = nil

        guard enabled else {
            apply {
                $0.fiveHour = nil
                $0.sevenDay = nil
                $0.failure = "無効"
            }
            return
        }

        let interval = max(interval, Self.minimumInterval)
        // Re-scheduling is not a reason to spend a request: only fetch now if
        // the data would be stale anyway.
        if let last = lastAttempt, Date().timeIntervalSince(last) < interval {
            // Coming back from disabled leaves that message behind, so restate
            // where we actually stand before waiting for the next tick.
            apply { $0.failure = self.waitingMessage() }

            let scheduled = Timer(fire: last.addingTimeInterval(interval), interval: interval, repeats: true) { [weak self] _ in
                self?.fetch()
            }
            RunLoop.main.add(scheduled, forMode: .common)
            timer = scheduled
            return
        }

        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    /// Non-nil only while a 429 backoff is still running.
    private func waitingMessage() -> String? {
        guard let retryAfter, Date() < retryAfter else { return nil }
        return "制限中 \(Self.wait(until: retryAfter))"
    }

    private func fetch() {
        guard !isFetching, settings.usageEnabled else { return }

        if let waiting = waitingMessage() {
            apply { $0.failure = waiting }
            return
        }
        lastAttempt = Date()

        guard let token = ClaudeCredentials.accessToken() else {
            apply { $0.failure = "未ログイン" }
            return
        }

        isFetching = true
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isFetching = false
                self.ingest(data: data, response: response, error: error)
            }
        }.resume()
    }

    private func ingest(data: Data?, response: URLResponse?, error: Error?) {
        if error != nil {
            apply { $0.failure = "接続できません" }
            return
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        if status == 429 || status >= 500 {
            backOff(retryAfterHeader: http?.value(forHTTPHeaderField: "Retry-After"))
            apply { $0.failure = self.waitingMessage() ?? "制限中" }
            return
        }

        guard status == 200 else {
            // 401 means the CLI has rotated the token since we read it; the
            // next tick picks up the new one.
            apply { $0.failure = status == 401 ? "認証切れ" : "HTTP \(status)" }
            return
        }

        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            apply { $0.failure = "解析できません" }
            return
        }

        retryAfter = nil
        consecutiveRejections = 0
        apply {
            $0.fiveHour = Self.window(from: object["five_hour"])
            $0.sevenDay = Self.window(from: object["seven_day"])
            $0.measuredAt = Date()
            $0.failure = nil
        }
        saveCache(snapshot)
    }

    /// Honours `Retry-After` when the server sends one, and otherwise doubles
    /// the wait per rejection so a rate limit isn't met with more requests.
    private func backOff(retryAfterHeader: String?) {
        consecutiveRejections += 1

        let delay: TimeInterval
        if let seconds = retryAfterHeader.flatMap(TimeInterval.init) {
            delay = seconds
        } else if let header = retryAfterHeader, let date = Self.httpDate(from: header) {
            delay = max(date.timeIntervalSinceNow, 0)
        } else {
            let interval = max(settings.usageRefreshInterval, Self.minimumInterval)
            delay = min(interval * pow(2, Double(consecutiveRejections)), Self.maximumBackoff)
        }

        retryAfter = Date().addingTimeInterval(min(max(delay, Self.minimumInterval), Self.maximumBackoff))
    }

    /// Rounds up, so a 60-second backoff reads as "1m" rather than "59s".
    private static func wait(until date: Date) -> String {
        let seconds = max(Int(date.timeIntervalSinceNow.rounded(.up)), 0)
        return seconds < 60 ? "\(seconds)s" : "\((seconds + 59) / 60)m"
    }

    private static func httpDate(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }

    /// Always republishes, even when the numbers are unchanged, so views that
    /// render a countdown to the reset tick along with it.
    private func apply(_ mutate: (inout UsageSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        next.fetchedAt = Date()
        snapshot = next
    }

    // MARK: - Cache

    private static let cacheKey = "usageSnapshotCache"

    private func loadCache() -> UsageSnapshot? {
        guard let data = cache.data(forKey: Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    private func saveCache(_ snapshot: UsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        cache.set(data, forKey: Self.cacheKey)
    }

    private static func window(from value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }

        let utilization: Double
        if let double = dict["utilization"] as? Double {
            utilization = double
        } else if let int = dict["utilization"] as? Int {
            utilization = Double(int)
        } else {
            return nil
        }

        return UsageWindow(
            percent: Int(utilization.rounded()),
            resetsAt: date(from: dict["resets_at"])
        )
    }

    private static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        // Timestamps carry microsecond precision, which the plain internet
        // date format rejects.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
