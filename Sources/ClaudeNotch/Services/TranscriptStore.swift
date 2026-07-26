import Combine
import Foundation

/// Loads and refreshes the transcript for whichever session is selected,
/// re-reading only when the file's modification date changes.
final class TranscriptStore: ObservableObject {
    @Published private(set) var detail: SessionDetail?

    private var session: ClaudeSession?
    private var url: URL?
    private var lastModified: Date?
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    init(settings: AppSettings = .shared) {
        cancellable = settings.$transcriptPollInterval
            .removeDuplicates()
            .sink { [weak self] interval in
                self?.restartTimer(interval: interval)
            }
    }

    deinit {
        timer?.invalidate()
    }

    private func restartTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.25), repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func select(_ session: ClaudeSession?) {
        guard session?.sessionId != self.session?.sessionId else { return }
        self.session = session
        self.lastModified = nil
        self.detail = nil
        self.url = session.flatMap(TranscriptReader.transcriptURL(for:))
        refresh()
    }

    private func refresh() {
        guard let url else { return }

        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let modified, modified == lastModified { return }
        lastModified = modified

        detail = TranscriptReader.load(from: url)
    }
}
