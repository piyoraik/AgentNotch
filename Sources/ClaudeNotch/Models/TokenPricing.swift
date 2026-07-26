import Foundation

/// List price for one model, in USD per million tokens.
struct ModelRate: Equatable, Sendable {
    let input: Double
    let output: Double

    /// Writing the prompt cache costs 1.25x the input rate at the 5 分 TTL,
    /// reading it back 0.1x. Claude Code also uses a 1 時間 TTL on some
    /// requests (2x to write) but the transcript doesn't record which, so the
    /// cheaper figure is used and long-lived caches are under-counted.
    var cacheWrite: Double { input * 1.25 }
    var cacheRead: Double { input * 0.1 }
}

/// Turns the token counts in a transcript into an approximate dollar figure.
///
/// **これは請求額ではない。** Claude Code の定額プランはトークン単位で
/// 課金されないため、ここで出るのは「同じ処理を従量課金の API で回したら
/// いくらか」という換算値。使用量の重さを掴むための目安として出す。
enum TokenPricing {
    /// Exact IDs, for models whose price differs from their tier.
    private static let known: [String: ModelRate] = [
        "claude-fable-5": ModelRate(input: 10, output: 50),
        "claude-mythos-5": ModelRate(input: 10, output: 50),
    ]

    /// Fallback by family keyword. Transcripts record dated snapshots
    /// (`claude-sonnet-4-5-20250929`) and new models ship faster than this
    /// table is updated, so an unknown ID still prices at its tier instead of
    /// dropping out of the total silently.
    private static let families: [(keyword: String, rate: ModelRate)] = [
        ("fable", ModelRate(input: 10, output: 50)),
        ("mythos", ModelRate(input: 10, output: 50)),
        ("haiku", ModelRate(input: 1, output: 5)),
        ("opus", ModelRate(input: 5, output: 25)),
        ("sonnet", ModelRate(input: 3, output: 15)),
    ]

    /// Sonnet 5 shipped with introductory pricing ($2/$10) that lapses at the
    /// end of 2026-08-31 UTC. Modelled rather than hard-coded so the estimate
    /// stops being wrong on its own the day the discount ends.
    private static let sonnet5IntroRate = ModelRate(input: 2, output: 10)
    private static let sonnet5IntroEnds: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)) ?? .distantPast
    }()

    static func rate(for model: String, on date: Date = Date()) -> ModelRate? {
        let id = model.lowercased()

        if id.hasPrefix("claude-sonnet-5"), date < sonnet5IntroEnds {
            return sonnet5IntroRate
        }
        if let exact = known[id] {
            return exact
        }
        return families.first { id.contains($0.keyword) }?.rate
    }

    /// Nil when the model is unrecognised, so callers can say "不明" rather
    /// than pass a zero off as "free".
    static func cost(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        model: String?,
        on date: Date = Date()
    ) -> Double? {
        guard let model, let rate = rate(for: model, on: date) else { return nil }
        let dollars = Double(input) * rate.input
            + Double(output) * rate.output
            + Double(cacheRead) * rate.cacheRead
            + Double(cacheWrite) * rate.cacheWrite
        return dollars / 1_000_000
    }

    static func cost(of tokens: TokenStats, model: String?, on date: Date = Date()) -> Double? {
        cost(
            input: tokens.input,
            output: tokens.output,
            cacheRead: tokens.cacheRead,
            cacheWrite: tokens.cacheWrite,
            model: model,
            on: date
        )
    }

    /// Compact for the notch: "$0.42", "<$0.01", "$1.2k".
    static func format(_ usd: Double) -> String {
        if usd <= 0 { return "$0.00" }
        if usd < 0.01 { return "<$0.01" }
        if usd < 1_000 { return String(format: "$%.2f", usd) }
        return String(format: "$%.1fk", usd / 1_000)
    }

    /// Full precision for reports, where the numbers get summed downstream.
    static func exact(_ usd: Double) -> String {
        String(format: "%.4f", usd)
    }
}
