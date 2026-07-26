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
    /// The windows move slowly and the endpoint is shared with the CLI; once a
    /// minute is plenty.
    private let interval: TimeInterval = 60

    private var timer: Timer?
    private var isFetching = false

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func fetch() {
        guard !isFetching else { return }

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

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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

        apply {
            $0.fiveHour = Self.window(from: object["five_hour"])
            $0.sevenDay = Self.window(from: object["seven_day"])
            $0.failure = nil
        }
    }

    /// Always republishes, even when the numbers are unchanged, so views that
    /// render a countdown to the reset tick along with it.
    private func apply(_ mutate: (inout UsageSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        next.fetchedAt = Date()
        snapshot = next
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
