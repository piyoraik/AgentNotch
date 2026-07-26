import AppKit
import Combine
import SwiftUI

final class NotchWindowController: NSWindowController {
    private let monitor: SessionMonitor
    private let summaries: SummaryStore
    private let approvals: ApprovalStore
    private let usage: UsageStore
    private let settings: AppSettings
    private let uiState = NotchUIState()
    private let transcripts = TranscriptStore()

    private var geometry: NotchGeometry?
    private var collapsedFrame: NSRect = .zero
    private var expandedFrame: NSRect = .zero
    private var isExpanded = false
    private var cancellables = Set<AnyCancellable>()
    /// Never torn down: the controller lives for the lifetime of the app.
    private var clickMonitor: Any?

    init(
        monitor: SessionMonitor,
        summaries: SummaryStore,
        approvals: ApprovalStore,
        usage: UsageStore,
        settings: AppSettings = .shared
    ) {
        self.monitor = monitor
        self.summaries = summaries
        self.approvals = approvals
        self.usage = usage
        self.settings = settings
        let panel = NotchWindow(contentRect: .zero)
        super.init(window: panel)
        configureFrames()
        installContentView()
        observeState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard settings.showNotchPanel else { return }
        window?.orderFrontRegardless()
    }

    private func configureFrames() {
        guard let geometry = ScreenLocator.notchGeometry() else { return }
        self.geometry = geometry

        let screen = geometry.screen
        // How far the black pill extends past each side of the physical notch,
        // giving us visible area to draw the session count and meters into.
        let wingWidth = CGFloat(settings.wingWidth)
        let collapsedWidth = geometry.hasNotch ? geometry.notchWidth + wingWidth * 2 : wingWidth * 2 + 56
        let collapsedHeight = max(geometry.notchHeight, 32)
        let expandedWidth = CGFloat(settings.panelWidth)
        let expandedHeight = CGFloat(settings.panelHeight)

        let topY = screen.frame.maxY
        let midX = screen.frame.midX

        collapsedFrame = NSRect(
            x: midX - collapsedWidth / 2,
            y: topY - collapsedHeight,
            width: collapsedWidth,
            height: collapsedHeight
        )
        expandedFrame = NSRect(
            x: midX - expandedWidth / 2,
            y: topY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )

        window?.setFrame(isExpanded ? expandedFrame : collapsedFrame, display: false)
    }

    private func installContentView() {
        guard let geometry else { return }
        let view = NotchContentView(
            monitor: monitor,
            uiState: uiState,
            transcripts: transcripts,
            summaries: summaries,
            approvals: approvals,
            usage: usage,
            settings: settings,
            notchWidth: geometry.hasNotch ? geometry.notchWidth : 0,
            collapsedHeight: max(geometry.notchHeight, 32)
        )
        window?.contentView = NSHostingView(rootView: view)
    }

    private func observeState() {
        uiState.$isHovering
            .combineLatest(uiState.$isPinned)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.setExpanded(expanded)
            }
            .store(in: &cancellables)

        // Size changes take effect without a relaunch; the panel is re-framed
        // in place and animated to the new geometry if it is already open.
        settings.$wingWidth
            .combineLatest(settings.$panelWidth, settings.$panelHeight)
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.configureFrames()
            }
            .store(in: &cancellables)

        settings.$showNotchPanel
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    self.window?.orderFrontRegardless()
                } else {
                    self.uiState.close()
                    self.window?.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        // An approval blocks a session until answered, so surface it without
        // waiting for the user to hover the notch.
        approvals.$pending
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] hasPending in
                guard let self else { return }
                guard hasPending else {
                    self.uiState.isPinned = false
                    if !self.settings.showNotchPanel { self.window?.orderOut(nil) }
                    return
                }
                // Hiding the panel must never leave a blocked session without
                // an answer surface, so an approval overrides the setting.
                self.window?.orderFrontRegardless()
                if self.settings.autoOpenOnApproval {
                    self.uiState.selectedSessionId = nil
                    self.uiState.isPinned = true
                }
            }
            .store(in: &cancellables)

        // A pinned panel stays open until the user clicks elsewhere.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // A pending approval must not be dismissed by a stray click; the
            // session stays blocked until it is answered.
            guard let self, self.uiState.isPinned, self.approvals.pending.isEmpty else { return }
            let point = NSEvent.mouseLocation
            if !self.expandedFrame.contains(point) {
                self.uiState.close()
            }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded, let window else { return }
        isExpanded = expanded
        let target = expanded ? expandedFrame : collapsedFrame

        NSAnimationContext.runAnimationGroup { context in
            // 開くときは少し粘って伸び、閉じるときは素早く畳む。SwiftUI 側の
            // `Motion.expand` と体感を合わせた値。
            context.duration = expanded ? 0.3 : 0.22
            context.timingFunction = expanded
                ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }
    }
}
