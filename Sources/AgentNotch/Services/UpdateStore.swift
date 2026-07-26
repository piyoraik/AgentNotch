import AppKit
import Combine
import Foundation

/// Checks GitHub for a newer release, and — once the archive's signature
/// checks out — swaps this bundle for it.
///
/// The repository is private, so the download needs credentials. Rather than
/// asking for a token and storing one, this shells out to the `gh` CLI the
/// user is already signed in to, the same way `ClaudeCredentials` borrows the
/// `claude` CLI's keychain entry instead of keeping its own copy. `gh` also
/// owns the awkward part of the GitHub download: a private asset redirects to
/// a signed S3 URL that rejects the request if the `Authorization` header
/// follows it there.
///
/// `@unchecked Sendable` because the work runs on `queue`; every `@Published`
/// mutation is hopped onto main first.
final class UpdateStore: ObservableObject, @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseUpdate)
        case downloading
        case verifying
        /// Verified and unpacked, waiting for the user to say when.
        case staged(ReleaseUpdate)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckedAt: Date?

    /// Non-nil when this build can't replace itself, with the reason to show.
    let installBlock: String?

    private static let repository = "piyoraik/AgentNotch"
    private static let bundleID = "com.piyoraik.AgentNotch"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Long enough for a slow link, short enough that a hung `gh` doesn't leave
    /// the UI saying "確認中…" forever.
    private static let networkTimeout: TimeInterval = 180

    private let settings: AppSettings
    private let defaults: UserDefaults
    /// Injected rather than read at the point of use so the flow can be
    /// exercised against a real release without shipping a build to match.
    private let currentVersion: AppVersion?
    private let queue = DispatchQueue(label: "com.piyoraik.AgentNotch.update", qos: .utility)
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Owned by `queue`. The unpacked bundle waiting to be moved into place.
    private var stagedApp: URL?
    private var stagingRoot: URL?
    private var isWorking = false

    init(
        settings: AppSettings = .shared,
        defaults: UserDefaults = .standard,
        currentVersion: AppVersion? = .current
    ) {
        self.settings = settings
        self.defaults = defaults
        self.currentVersion = currentVersion
        installBlock = Self.blockReason(for: Bundle.main.bundleURL)
        lastCheckedAt = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    deinit {
        timer?.invalidate()
    }

    /// Checks once shortly after launch and then daily, unless switched off.
    /// The delay keeps a `gh` invocation off the launch path.
    func start() {
        queue.async { [weak self] in self?.discardStaleStaging() }

        settings.$automaticUpdateChecks
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.reschedule(enabled: enabled)
            }
            .store(in: &cancellables)
    }

    private func reschedule(enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled, installBlock == nil else { return }

        let elapsed = lastCheckedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if elapsed >= Self.checkInterval {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.settings.automaticUpdateChecks else { return }
                self.check()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    // MARK: - 確認

    func check() {
        guard begin() else { return }
        publish(.checking)

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.end() }

            guard let gh = Self.locateGH() else {
                self.publish(.failed("gh コマンドが見つかりません"))
                return
            }

            let result = Self.run(gh, ["api", "repos/\(Self.repository)/releases/latest"],
                                  timeout: Self.networkTimeout)
            guard result.succeeded else {
                self.publish(.failed(Self.describe(ghFailure: result)))
                return
            }

            let now = Date()
            DispatchQueue.main.async {
                self.lastCheckedAt = now
                self.defaults.set(now, forKey: Self.lastCheckKey)
            }

            guard let update = Self.parseRelease(result.stdout) else {
                self.publish(.failed("リリース情報を読めません"))
                return
            }
            guard let current = self.currentVersion else {
                self.publish(.failed("このビルドのバージョンが読めません"))
                return
            }
            // 同じか古いものは出さない。署名が通る古い版を配って戻させる、という
            // 手を塞ぐ意味もある。
            guard update.version > current else {
                self.publish(.upToDate)
                return
            }
            self.publish(.available(update))
        }
    }

    // MARK: - 取得と検証

    func download() {
        guard case .available(let update) = phase else { return }
        guard begin() else { return }
        publish(.downloading)

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.end() }

            guard let gh = Self.locateGH() else {
                self.publish(.failed("gh コマンドが見つかりません"))
                return
            }

            let root: URL
            do {
                root = try self.makeStagingDirectory()
            } catch {
                self.publish(.failed("作業ディレクトリを作れません"))
                return
            }

            let download = Self.run(gh, [
                "release", "download", update.tag,
                "--repo", Self.repository,
                "--pattern", update.archiveName,
                "--pattern", update.signatureName,
                "--dir", root.path,
            ], timeout: Self.networkTimeout)

            guard download.succeeded else {
                try? FileManager.default.removeItem(at: root)
                self.publish(.failed(Self.describe(ghFailure: download)))
                return
            }

            self.publish(.verifying)

            let archive = root.appendingPathComponent(update.archiveName)
            let signature = root.appendingPathComponent(update.signatureName)
            guard let archiveData = try? Data(contentsOf: archive),
                  let signatureText = try? String(contentsOf: signature, encoding: .utf8)
            else {
                try? FileManager.default.removeItem(at: root)
                self.publish(.failed("署名付きの配布物が揃っていません"))
                return
            }

            // ここから先は、署名を通ったものしか触らない。
            guard ReleaseSignature.isValid(data: archiveData, signature: signatureText) else {
                try? FileManager.default.removeItem(at: root)
                self.publish(.failed("署名が一致しません。更新を中止しました"))
                return
            }

            let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
            let unzip = Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], timeout: 120)
            guard unzip.succeeded,
                  let app = Self.appBundle(in: unpacked)
            else {
                try? FileManager.default.removeItem(at: root)
                self.publish(.failed("配布物を展開できません"))
                return
            }

            // 署名は zip の中身までしか保証しない。中の .app が名乗っているものが
            // 期待どおりかは別に見る。
            guard let info = Self.infoDictionary(of: app),
                  info["CFBundleIdentifier"] as? String == Self.bundleID,
                  let staged = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
                  staged == update.version
            else {
                try? FileManager.default.removeItem(at: root)
                self.publish(.failed("配布物の中身が一致しません"))
                return
            }

            self.stagingRoot = root
            self.stagedApp = app
            self.publish(.staged(update))
        }
    }

    // MARK: - 入れ替え

    /// Hands the swap to a detached script, because a bundle cannot replace
    /// itself while it is the thing running.
    func install() {
        guard case .staged = phase, installBlock == nil else { return }
        publish(.installing)

        queue.async { [weak self] in
            guard let self, let staged = self.stagedApp, let root = self.stagingRoot else { return }

            let destination = Bundle.main.bundleURL
            let bridge = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AgentNotch/bin")
            let script = root.appendingPathComponent("install.sh")

            do {
                try Data(Self.installerScript.utf8).write(to: script)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            } catch {
                self.publish(.failed("入れ替えの準備に失敗しました"))
                return
            }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [
                script.path,
                String(ProcessInfo.processInfo.processIdentifier),
                staged.path,
                destination.path,
                bridge.path,
                root.path,
            ]
            do {
                try task.run()
            } catch {
                self.publish(.failed("入れ替えを開始できません"))
                return
            }

            // 終了しないと、ヘルパーは待ち続けたまま何もしない。
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Runs after this process exits, so nothing here can touch the app's own
    /// memory — everything it needs arrives as arguments.
    ///
    /// The old bundle is moved aside rather than deleted, so a failed copy can
    /// put it back instead of leaving the user with no app at all.
    private static let installerScript = """
    #!/bin/bash
    set -u
    PID="$1"; STAGED="$2"; DEST="$3"; BRIDGE="$4"; ROOT="$5"

    for _ in $(seq 100); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.1
    done
    # まだ生きているなら、掴まれたままのバンドルを触らずに諦める。
    kill -0 "$PID" 2>/dev/null && exit 1

    if [ -e "$DEST" ]; then
      existing=$(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "")
      [ "$existing" = "com.piyoraik.AgentNotch" ] || exit 1
    fi

    xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true

    BACKUP="$DEST.old-$$"
    if [ -e "$DEST" ]; then
      mv "$DEST" "$BACKUP" || exit 1
    fi

    if /usr/bin/ditto "$STAGED" "$DEST"; then
      rm -rf "$BACKUP"
    else
      rm -rf "$DEST"
      [ -e "$BACKUP" ] && mv "$BACKUP" "$DEST"
      open "$DEST"
      exit 1
    fi

    # フックが読むのはアプリの外のコピー。ここで揃えないと古い版が残る。
    mkdir -p "$BRIDGE"
    /usr/bin/ditto "$DEST/Contents/MacOS/agentnotch-bridge" "$BRIDGE/agentnotch-bridge" 2>/dev/null

    open "$DEST"
    rm -rf "$ROOT"
    """

    // MARK: - 下ごしらえ

    private static let lastCheckKey = "lastUpdateCheckAt"

    /// Refuses to overwrite a build that came out of Xcode: replacing it with a
    /// release would quietly discard whatever was being worked on.
    private static func blockReason(for bundle: URL) -> String? {
        if bundle.path.contains("/DerivedData/") {
            return "開発ビルドのため、アプリからの更新は行いません"
        }
        if !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return "この場所には書き込めないため、アプリからの更新は行えません"
        }
        return nil
    }

    private func begin() -> Bool {
        var allowed = false
        queue.sync {
            if !isWorking {
                isWorking = true
                allowed = true
            }
        }
        return allowed
    }

    private func end() {
        queue.async { self.isWorking = false }
    }

    private func publish(_ next: Phase) {
        DispatchQueue.main.async { self.phase = next }
    }

    private var updatesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentNotch/updates", isDirectory: true)
    }

    private func makeStagingDirectory() throws -> URL {
        let root = updatesDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A download that was never installed is just wasted disk; clear it out
    /// at launch rather than accumulating one per skipped version.
    private func discardStaleStaging() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: updatesDirectory,
                                                             includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            try? manager.removeItem(at: entry)
        }
    }

    private static func appBundle(in directory: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension == "app" }
    }

    private static func infoDictionary(of app: URL) -> [String: Any]? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    private static func parseRelease(_ json: String) -> ReleaseUpdate? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = AppVersion(tag)
        else { return nil }

        let assets = (object["assets"] as? [[String: Any]]) ?? []
        let names = assets.compactMap { $0["name"] as? String }
        // 署名が並んでいない配布物は、そもそも取りに行かない。
        guard let archive = names.first(where: { $0.hasSuffix(".zip") }),
              names.contains(archive + ".sig")
        else { return nil }

        return ReleaseUpdate(
            version: version,
            tag: tag,
            archiveName: archive,
            pageURL: (object["html_url"] as? String).flatMap(URL.init(string:)),
            publishedAt: (object["published_at"] as? String).flatMap {
                try? Date($0, strategy: .iso8601)
            }
        )
    }

    private static func describe(ghFailure result: Command) -> String {
        let text = result.stderr + result.stdout
        if text.contains("gh auth login") || text.contains("authentication") {
            return "gh がログインしていません"
        }
        if text.contains("Could not resolve") || text.contains("dial tcp") {
            return "接続できません"
        }
        if text.contains("404") {
            return "リリースが見つかりません（リポジトリへのアクセス権を確認）"
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? "不明なエラー"
        return String(firstLine.prefix(80))
    }

    // MARK: - 外部コマンド

    private struct Command {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }
    }

    /// GUI apps inherit a minimal `PATH`, so `gh` has to be found by looking.
    private static func locateGH() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/opt/local/bin/gh",
            "/usr/bin/gh",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // 最後の手段。ログインシェルなら利用者の PATH が読み込まれる。
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let lookup = run(shell, ["-lc", "command -v gh"], timeout: 10)
        let path = lookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return lookup.succeeded && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Output goes to files rather than pipes: draining one pipe while the
    /// child fills the other is the classic way to deadlock a `Process`.
    private static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> Command {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil
        else { return Command(status: -1, stdout: "", stderr: "一時ディレクトリを作れません") }

        let outURL = scratch.appendingPathComponent("out")
        let errURL = scratch.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL)
        else { return Command(status: -1, stdout: "", stderr: "出力を受け取れません") }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        task.standardOutput = outHandle
        task.standardError = errHandle
        task.standardInput = FileHandle.nullDevice

        // gh は内部で git を起動する。最小の PATH のままだと見つけられない。
        var environment = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = environment["PATH"].map { "\($0):\(extra)" } ?? extra
        task.environment = environment

        do { try task.run() } catch {
            return Command(status: -1, stdout: "", stderr: "\(launchPath) を起動できません")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            task.terminate()
            _ = try? outHandle.close()
            _ = try? errHandle.close()
            return Command(status: -1, stdout: "", stderr: "応答がないため中断しました")
        }
        task.waitUntilExit()
        _ = try? outHandle.close()
        _ = try? errHandle.close()

        return Command(
            status: task.terminationStatus,
            stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        )
    }
}
