import Combine
import Foundation

/// Standing approvals, persisted in `UserDefaults`.
///
/// Kept out of `AppSettings` because these are security decisions rather than
/// preferences: they need their own list UI and their own reset.
///
/// `@unchecked Sendable` because `ApprovalStore` reads it from a plain
/// (non-isolated) class; every access is hopped onto main first.
final class AlwaysAllowStore: ObservableObject, @unchecked Sendable {
    static let shared = AlwaysAllowStore()

    @Published private(set) var rules: [AlwaysAllowRule] = []

    private let defaults: UserDefaults
    private let key = "alwaysAllowRules"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = load()
    }

    /// The single question the approval path asks.
    func allows(_ request: ApprovalRequest) -> Bool {
        rules.contains { $0.matches(request) }
    }

    func add(_ rule: AlwaysAllowRule) {
        // A tool-wide rule subsumes every narrower rule already stored for it.
        if rule.scope == .tool {
            rules.removeAll { $0.toolName == rule.toolName }
        } else if rules.contains(where: { $0.matches(exactly: rule) }) {
            return
        }
        rules.append(rule)
        persist()
    }

    func remove(_ rule: AlwaysAllowRule) {
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    func removeAll() {
        rules.removeAll()
        persist()
    }

    private func load() -> [AlwaysAllowRule] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AlwaysAllowRule].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
    }
}

private extension AlwaysAllowRule {
    /// Same tool, scope, and target — used to avoid storing duplicates.
    func matches(exactly other: AlwaysAllowRule) -> Bool {
        toolName == other.toolName && scope == other.scope && value == other.value
    }
}
