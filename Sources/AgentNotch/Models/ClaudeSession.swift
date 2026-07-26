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

    /// Whether the session still has the turn — anything that isn't `idle`.
    ///
    /// `status` has at least three values: `busy`, `idle`, and `waiting`. The
    /// last one appears for well under a poll interval in the middle of a run
    /// (measured: five `busy → waiting → busy` flickers in three minutes of
    /// one session working), so `isBusy` alone reads a turn in progress as a
    /// series of finished ones. Only `idle` means the user has it back.
    var isWorking: Bool {
        status != "idle"
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
