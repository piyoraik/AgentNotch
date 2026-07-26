import AppKit

/// Brings the terminal running a given `claude` process to the front.
///
/// The claude pid's controlling tty is the join key: iTerm2 and Terminal both
/// expose `tty` on their tabs, so the exact tab can be selected rather than
/// just raising the app.
enum TerminalLocator {
    static func reveal(pid: Int32) {
        guard let app = terminalApp(for: pid) else { return }
        app.activate()

        guard let tty = tty(for: pid) else { return }
        switch app.bundleIdentifier {
        case "com.googlecode.iterm2":
            run(iTermScript(tty: tty))
        case "com.apple.Terminal":
            run(terminalScript(tty: tty))
        default:
            // Unknown emulator: raising the app is the best we can do.
            break
        }
    }

    /// True when we can at least raise the owning terminal.
    static func canReveal(pid: Int32) -> Bool {
        terminalApp(for: pid) != nil
    }

    // MARK: - Process inspection

    private static func tty(for pid: Int32) -> String? {
        guard let output = shell("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty, output != "??"
        else { return nil }
        return output.hasPrefix("/dev/") ? output : "/dev/\(output)"
    }

    /// Walks the parent chain until it hits a process that owns a GUI app —
    /// for iTerm2 that skips past login, the shell, and iTermServer.
    private static func terminalApp(for pid: Int32) -> NSRunningApplication? {
        guard let table = shell("/bin/ps", ["-eo", "pid=,ppid="]) else { return nil }

        var parents: [Int32: Int32] = [:]
        for line in table.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let child = Int32(parts[0]), let parent = Int32(parts[1]) else { continue }
            parents[child] = parent
        }

        var current = pid
        for _ in 0..<12 {
            guard let parent = parents[current], parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.bundleIdentifier != nil {
                return app
            }
            current = parent
        }
        return nil
    }

    private static func shell(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - AppleScript

    private static func run(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }
}
