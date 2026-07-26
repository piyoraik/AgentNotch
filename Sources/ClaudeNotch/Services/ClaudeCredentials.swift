import Foundation

/// Reads the OAuth access token the `claude` CLI stores for the signed-in
/// account. The CLI rotates it roughly hourly, so callers should re-read
/// rather than hold on to one.
enum ClaudeCredentials {
    private static let service = "Claude Code-credentials"

    static func accessToken() -> String? {
        keychainToken() ?? fileToken()
    }

    /// Shells out to `security` instead of calling `SecItemCopyMatching`:
    /// a keychain ACL is bound to the calling binary, and an ad-hoc signed
    /// build gets a fresh identity on every rebuild, which would re-prompt
    /// the user each time. `/usr/bin/security` keeps one stable identity.
    private static func keychainToken() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", service, "-w"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else { return nil }
        return token(from: data)
    }

    /// Used when the keychain is unavailable — the CLI falls back to this file
    /// too (`CLAUDE_CODE_USE_KEYCHAIN=0`, remote sessions).
    private static func fileToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return token(from: data)
    }

    private static func token(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }
}
