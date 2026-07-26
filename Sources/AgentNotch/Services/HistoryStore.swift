import Combine
import Foundation

/// 過去のセッションを `~/.claude/projects` から読み出す。
///
/// ここだけは他のストアと違ってタイマーを持たない。履歴は勝手に増えるもの
/// ではなく「見に行くもの」なので、ウィンドウを開いた（前面に出した）ときに
/// 走査する。常時ポーリングすると、閉じている窓のために毎秒 30MB 分の
/// ディレクトリを撫でることになる。
///
/// `@unchecked Sendable`: 走査は専用キューで行い、`@Published` の代入は
/// 必ず main に戻してから行う。
final class HistoryStore: ObservableObject, @unchecked Sendable {
    /// 新しい順。
    @Published private(set) var records: [SessionRecord] = []
    @Published private(set) var isScanning = false
    /// 一度でも走査を終えたか。空の一覧を「まだ読んでいない」と
    /// 「1 本も無い」で描き分けるため。
    @Published private(set) var hasScanned = false

    /// 選択中のセッションの全文。行を選ぶまでは読まない。
    @Published private(set) var detail: SessionDetail?
    @Published private(set) var isLoadingDetail = false

    /// 走査用。`cache` はこのキューだけが触る。
    private let queue = DispatchQueue(label: "com.piyoraik.AgentNotch.history", qos: .userInitiated)
    private var cache: [String: Entry] = [:]
    private var isScanningNow = false

    /// 今開いているセッション。読み終わった詳細が別の行のものでないか
    /// 確かめるために持つ（main が所有）。
    private var selectedID: String?

    /// 走査の途中経過。追記されたぶんだけ読み直せるように、
    /// `SummaryScan` のバイトオフセットごと覚えておく。
    private struct Entry {
        var scan: TranscriptReader.SummaryScan
        var size: UInt64
        var modified: Date
    }

    private var projectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // MARK: - 走査

    func refresh() {
        queue.async { [weak self] in
            guard let self, !self.isScanningNow else { return }
            self.isScanningNow = true
            DispatchQueue.main.async { self.isScanning = true }

            let records = self.scan()

            DispatchQueue.main.async {
                self.isScanningNow = false
                self.isScanning = false
                self.hasScanned = true
                if records != self.records { self.records = records }
            }
        }
    }

    /// 変わっていないファイルは前回の結果をそのまま使い、伸びたファイルは
    /// 追記分だけを読む。初回だけ全文（実測 32MB で 0.4 秒前後）。
    private func scan() -> [SessionRecord] {
        dispatchPrecondition(condition: .onQueue(queue))

        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var records: [SessionRecord] = []
        var seen: Set<String> = []

        for directory in directories {
            let files = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = UInt64(values?.fileSize ?? 0)
                let modified = values?.contentModificationDate ?? .distantPast

                let cached: Entry? = cache[file.path]
                let entry: Entry
                if let cached, cached.size == size, cached.modified == modified {
                    entry = cached
                } else {
                    // 前回の続きがあればそこから、無ければ既定（先頭から）。
                    // `SummaryScan` は自前で作れないので、初回は引数を省く。
                    let scan: TranscriptReader.SummaryScan
                    if let cached {
                        scan = TranscriptReader.scanSummary(from: file, resuming: cached.scan)
                    } else {
                        scan = TranscriptReader.scanSummary(from: file)
                    }
                    entry = Entry(scan: scan, size: size, modified: modified)
                    cache[file.path] = entry
                }

                let record = SessionRecord(
                    sessionId: file.deletingPathExtension().lastPathComponent,
                    url: file,
                    summary: entry.scan.summary,
                    modified: modified
                )
                // 同じ sessionId が 2 つの `<encoded-cwd>` に現れることがある
                // （ディレクトリを移してから再開した場合）。新しい方を採る。
                guard !record.isEmpty, seen.insert(record.sessionId).inserted else { continue }
                records.append(record)
            }
        }

        // 消えたファイルのぶんをキャッシュから落とす。履歴は開くたびに
        // 走査するので、放っておくと消えたセッションを抱えたままになる。
        let alive = Set(records.map { $0.url.path })
        cache = cache.filter { alive.contains($0.key) }

        return records.sorted { $0.endedAt > $1.endedAt }
    }

    // MARK: - 詳細

    func select(_ record: SessionRecord?) {
        guard record?.sessionId != selectedID else { return }
        selectedID = record?.sessionId
        detail = nil

        guard let record else {
            isLoadingDetail = false
            return
        }

        isLoadingDetail = true
        let expected = record.sessionId
        queue.async { [weak self] in
            // 履歴は途中が読めないと振り返りにならないので、末尾で切らない。
            let detail = TranscriptReader.load(from: record.url, messageLimit: nil, memoryLimit: nil)
            DispatchQueue.main.async {
                guard let self, self.selectedID == expected else { return }
                self.isLoadingDetail = false
                self.detail = detail
            }
        }
    }
}
