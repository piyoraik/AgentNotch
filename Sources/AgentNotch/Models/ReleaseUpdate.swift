import Foundation

/// A version as `major.minor.patch`, compared numerically.
///
/// String comparison would call 0.9.0 newer than 0.10.0, which is exactly the
/// case this project reaches next.
struct AppVersion: Equatable, Comparable, CustomStringConvertible {
    let components: [Int]

    /// Accepts an optional leading `v`, so a git tag and a bundle version parse
    /// the same way. Anything that is not a run of dot-separated numbers is
    /// rejected rather than guessed at.
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }
        components = numbers
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        // 0.10 と 0.10.0 を同じものとして扱えるよう、短いほうを 0 で埋める。
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// The version this build reports, from the bundle.
    static var current: AppVersion? {
        guard let string = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(string)
    }
}

/// A release newer than the running build, as described by the GitHub API.
struct ReleaseUpdate: Equatable {
    let version: AppVersion
    /// The git tag, needed verbatim to ask `gh` for its assets.
    let tag: String
    let archiveName: String
    let pageURL: URL?
    let publishedAt: Date?

    /// The detached signature sits beside the archive under the same name.
    var signatureName: String { archiveName + ".sig" }
}
