import Darwin
import Foundation

struct ClaudeSession: Codable, Identifiable, Equatable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Double
    let version: String?
    let kind: String?
    let entrypoint: String?
    let name: String?
    let status: String?
    let updatedAt: Double?

    var id: String { sessionId }

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    var displayName: String {
        name ?? projectName
    }

    var isBusy: Bool {
        status == "busy"
    }

    var startedDate: Date {
        Date(timeIntervalSince1970: startedAt / 1000)
    }

    /// Session files can linger after a `claude` process exits, so liveness
    /// is verified against the actual pid rather than trusted from disk.
    var isProcessAlive: Bool {
        kill(pid, 0) == 0
    }
}
