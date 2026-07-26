import Combine
import Foundation

/// Loads and refreshes the transcript for whichever session is selected,
/// re-reading only when the file's modification date changes.
///
/// `@unchecked Sendable` because the parse runs on a background queue; the
/// published detail is only assigned on main.
final class TranscriptStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var detail: SessionDetail?

    private var session: ClaudeSession?
    private var url: URL?
    private var lastModified: Date?
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    private let queue = DispatchQueue(label: "com.piyoraik.ClaudeNotch.transcript", qos: .userInitiated)
    private var isLoading = false

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
        self.url = nil

        guard let session else { return }
        // Resolving the path can walk every project directory, so it waits for
        // the background queue along with the parse.
        queue.async { [weak self] in
            let url = TranscriptReader.transcriptURL(for: session)
            DispatchQueue.main.async {
                // The user may have moved on while we were looking.
                guard let self, self.session?.sessionId == session.sessionId else { return }
                self.url = url
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard let url, !isLoading else { return }

        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let modified, modified == lastModified { return }
        lastModified = modified

        isLoading = true
        let expected = session?.sessionId
        queue.async { [weak self] in
            let detail = TranscriptReader.load(from: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                guard self.session?.sessionId == expected else { return }
                if detail != self.detail {
                    self.detail = detail
                }
            }
        }
    }
}
