import AppKit
import Darwin

/// Brings the terminal running a given `claude` process to the front.
///
/// iTerm2 and Terminal both expose `tty` on their tabs, so the claude pid's
/// controlling tty is an exact join key and the tab can be selected outright.
/// Ghostty's scripting dictionary has no `tty` — see `revealGhostty` for what
/// stands in for it.
enum TerminalLocator {
    private enum Emulator {
        static let iTerm2 = "com.googlecode.iterm2"
        static let terminal = "com.apple.Terminal"
        static let ghostty = "com.mitchellh.ghostty"
    }

    /// Where the `ps` calls happen. The AppleScript deliberately does *not* run
    /// here — see `apply`.
    private static let queue = DispatchQueue(label: "com.piyoraik.AgentNotch.TerminalLocator")

    /// Everything needed to drive the emulator, gathered off the main thread so
    /// that only the AppleScript is left to run on it.
    private struct Target: Sendable {
        let appPID: pid_t
        let bundleID: String
        var tty: String?
        var workingDirectory: String?
    }

    /// `title` is only used by emulators that cannot be matched on tty. Pass the
    /// session title AgentNotch already shows; Claude Code writes the same
    /// string to the terminal title, which is what makes it a usable key.
    static func reveal(pid: Int32, title: String? = nil) {
        queue.async {
            guard let target = inspect(pid: pid) else { return }
            DispatchQueue.main.async { apply(target, title: title) }
        }
    }

    /// Walking the process table costs a `ps` fork per call, so it is kept off
    /// the main thread even though the AppleScript that follows cannot be.
    private static func inspect(pid: Int32) -> Target? {
        guard let app = terminalApp(for: pid), let bundleID = app.bundleIdentifier else { return nil }
        var target = Target(appPID: app.processIdentifier, bundleID: bundleID)
        switch bundleID {
        case Emulator.iTerm2, Emulator.terminal:
            target.tty = tty(for: pid)
        case Emulator.ghostty:
            target.workingDirectory = workingDirectory(of: pid)
        default:
            break
        }
        return target
    }

    /// **Must run on the main thread.** AppleScript waits for the Apple Event
    /// reply by pumping a Carbon event loop on the calling thread
    /// (`UASRemoteSend` → `AEDefaultActiveProc` → `GetNextEventMatchingMask`),
    /// but the reply is delivered to the main thread's event queue. Called from
    /// anywhere else it returns sometimes and blocks forever the rest of the
    /// time — and one blocked call wedges every later reveal behind it.
    ///
    /// The cost lands on a click: roughly 90ms per round trip once warm, and
    /// Ghostty needs two (enumerate, then focus).
    private static func apply(_ target: Target, title: String?) {
        NSRunningApplication(processIdentifier: target.appPID)?.activate()

        switch target.bundleID {
        case Emulator.iTerm2:
            guard let tty = target.tty else { return }
            run(iTermScript(tty: tty))
        case Emulator.terminal:
            guard let tty = target.tty else { return }
            run(terminalScript(tty: tty))
        case Emulator.ghostty:
            revealGhostty(workingDirectory: target.workingDirectory, title: title)
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

    /// Current directory of a process, without shelling out to `lsof`. Only
    /// works for processes of the same user, which is all we ever ask about.
    private static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
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

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
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

    // MARK: - Ghostty

    private struct GhosttyTerminal {
        let id: String
        let workingDirectory: String
        let title: String
    }

    /// Ghostty exposes no `tty`, so the surface has to be recognised from what
    /// it does publish: the shell's working directory (reported over OSC 7) and
    /// the terminal title. Neither is sufficient alone — opening several
    /// sessions in one repository is normal, and titles only exist once Claude
    /// Code has written one — so the directory narrows and the title decides.
    ///
    /// When that still leaves more than one candidate we stop rather than
    /// guess: the app is already frontmost, and landing on the wrong session is
    /// worse than landing on no tab at all.
    private static func revealGhostty(workingDirectory: String?, title: String?) {
        let terminals = ghosttyTerminals()
        guard !terminals.isEmpty else { return }

        let key = normalizedTitle(title)
        var sameDirectory: [GhosttyTerminal] = []
        if let workingDirectory {
            let wanted = resolved(workingDirectory)
            sameDirectory = terminals.filter { resolved($0.workingDirectory) == wanted }
        }

        if let match = onlyTerminal(in: sameDirectory, matching: key) {
            focusGhostty(match)
        } else if sameDirectory.isEmpty, let match = onlyTerminal(in: terminals, matching: key) {
            // The cwd was unreadable, or the shell has wandered since launch.
            focusGhostty(match)
        } else if sameDirectory.count == 1 {
            focusGhostty(sameDirectory[0])
        }
    }

    private static func onlyTerminal(
        in terminals: [GhosttyTerminal],
        matching key: String?
    ) -> GhosttyTerminal? {
        guard let key else { return nil }
        let hits = terminals.filter { titleMatches($0.title, key) }
        return hits.count == 1 ? hits.first : nil
    }

    /// Claude Code prefixes the terminal title with a marker that changes as it
    /// works (`⠐ `, `✳ `), so the decoration has to come off before two titles
    /// can be compared. Anything leading that is neither a letter nor a digit
    /// is decoration — dropped from both sides, so a title that genuinely
    /// starts with a symbol still compares equal to itself.
    private static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title
            .drop { !$0.isLetter && !$0.isNumber }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The two sides can disagree on length: Claude Code truncates long titles,
    /// and AgentNotch falls back to the last prompt when a session has no
    /// `ai-title` yet. Agreeing on a prefix is enough, but only once there is
    /// enough of it to mean something — otherwise every session that is still
    /// showing the generic title would match every other one.
    private static func titleMatches(_ candidate: String, _ key: String) -> Bool {
        guard let candidate = normalizedTitle(candidate) else { return false }
        if candidate == key { return true }
        guard min(candidate.count, key.count) >= 8 else { return false }
        return candidate.hasPrefix(key) || key.hasPrefix(candidate)
    }

    /// `proc_pidinfo` hands back a resolved path while Ghostty reports the
    /// shell's logical `$PWD`, so `/tmp` on one side and `/private/tmp` on the
    /// other have to be reconciled before comparing.
    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// One round trip for every surface, because matching happens in Swift:
    /// stripping the title marker inside AppleScript is not worth it, and a
    /// per-surface query would pay the ~90ms round trip several times over.
    private static func ghosttyTerminals() -> [GhosttyTerminal] {
        let source = """
        tell application "Ghostty"
            set out to {}
            repeat with s in terminals
                set end of out to {id of s, working directory of s, name of s}
            end repeat
            return out
        end tell
        """
        guard let list = run(source) else { return [] }
        guard list.numberOfItems > 0 else { return [] }

        return (1...list.numberOfItems).compactMap { index in
            guard let row = list.atIndex(index),
                  let id = row.atIndex(1)?.stringValue,
                  let workingDirectory = row.atIndex(2)?.stringValue,
                  let title = row.atIndex(3)?.stringValue
            else { return nil }
            // The id goes back out inside a quoted AppleScript literal. Ghostty
            // hands out UUIDs today; refuse anything that could close the quote
            // rather than trusting that to hold.
            guard !id.contains("\""), !id.contains("\\") else { return nil }
            return GhosttyTerminal(id: id, workingDirectory: workingDirectory, title: title)
        }
    }

    private static func focusGhostty(_ terminal: GhosttyTerminal) {
        // `focus` raises the window *and* selects the tab, so there is no
        // window/tab/session sequence to walk as there is for iTerm2.
        run("""
        tell application "Ghostty"
            focus (first terminal whose id is "\(terminal.id)")
        end tell
        """)
    }
}
