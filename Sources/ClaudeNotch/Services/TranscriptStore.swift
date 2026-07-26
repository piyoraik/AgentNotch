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

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
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
