import AppKit
import Combine

/// Everything that pokes the user lives here: the sound, the Dock attention
/// request, and the short-lived "just finished" badge in the pill.
///
/// Three things can interrupt someone — an approval, a finished run, a session
/// waiting on the terminal — and they were never going to stay consistent if
/// each store made its own noise.
///
/// `@unchecked Sendable` for the delayed badge cleanup: everything here runs on
/// main, including the block that clears the badge later.
final class AlertCenter: ObservableObject, @unchecked Sendable {
    /// Sessions that finished within the last few seconds, for the pill badge.
    @Published private(set) var recentlyFinished: [FinishedSession] = []

    /// Long enough to catch on a glance back at the screen, short enough that
    /// the pill is telling the truth about the present most of the time.
    private static let badgeDuration: TimeInterval = 8

    private let approvals: ApprovalStore
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private var announcedApprovals: Set<String> = []
    private var announcedNotices: Set<String> = []

    init(
        monitor: SessionMonitor,
        approvals: ApprovalStore,
        notices: NoticeStore,
        settings: AppSettings = .shared
    ) {
        self.approvals = approvals
        self.settings = settings

        monitor.finished
            .sink { [weak self] finish in
                self?.announce(finish)
            }
            .store(in: &cancellables)

        // Both of these publish the whole collection on every change, so the
        // ids already announced are remembered rather than re-alerted. The
        // emitted value is used instead of reading the store back: `@Published`
        // fires on willSet, so the property is still the old one here.
        approvals.$pending
            .sink { [weak self] pending in
                self?.announceNew(
                    ids: pending.map(\.id),
                    seen: \.announcedApprovals,
                    play: { settings.playSoundOnApproval ? settings.approvalSoundName : nil },
                    bounce: { settings.bounceOnApproval }
                )
            }
            .store(in: &cancellables)

        notices.$notices
            .sink { [weak self] notices in
                self?.announceNew(
                    ids: notices.map { "\($0.id)-\($0.receivedAt.timeIntervalSince1970)" },
                    seen: \.announcedNotices,
                    play: { settings.playSoundOnWaiting ? settings.approvalSoundName : nil },
                    bounce: { false }
                )
            }
            .store(in: &cancellables)
    }

    // MARK: - Completion

    private func announce(_ finish: FinishedSession) {
        guard settings.notifyOnCompletion else { return }
        // A turn that came back in a moment was answered while the user was
        // still looking at the terminal.
        guard finish.busyDuration >= settings.completionMinimumSeconds else { return }
        // The session stopped working because it is waiting for an answer we
        // are already showing; that is not a finished run.
        guard !approvals.isBlocked(sessionId: finish.sessionId) else { return }

        recentlyFinished.removeAll { $0.id == finish.id }
        recentlyFinished.append(finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.badgeDuration) { [weak self] in
            self?.recentlyFinished.removeAll { $0.id == finish.id && $0.finishedAt == finish.finishedAt }
        }

        if settings.playSoundOnCompletion {
            NSSound(named: settings.completionSoundName)?.play()
        }
    }

    // MARK: - Arrivals

    /// Alerts once per id, on the ids that weren't in the previous collection.
    private func announceNew(
        ids: [String],
        seen keyPath: ReferenceWritableKeyPath<AlertCenter, Set<String>>,
        play sound: () -> String?,
        bounce: () -> Bool
    ) {
        let current = Set(ids)
        let isNew = !current.subtracting(self[keyPath: keyPath]).isEmpty
        // Ids that went away are forgotten, so the same request coming back
        // later alerts again.
        self[keyPath: keyPath] = current
        guard isNew else { return }

        if bounce() {
            // `NSApp` is main-actor isolated and this runs from a Combine sink,
            // which the compiler can't see is already on main. Hopping first
            // makes the assumption true by construction rather than by promise.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = NSApp.requestUserAttention(.informationalRequest)
                }
            }
        }
        if let name = sound() {
            NSSound(named: name)?.play()
        }
    }
}
