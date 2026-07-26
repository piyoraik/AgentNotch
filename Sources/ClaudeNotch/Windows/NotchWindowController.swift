import AppKit
import Combine
import SwiftUI

final class NotchWindowController: NSWindowController {
    private let monitor: SessionMonitor
    private let summaries: SummaryStore
    private let approvals: ApprovalStore
    private let usage: UsageStore
    private let uiState = NotchUIState()
    private let transcripts = TranscriptStore()

    private var geometry: NotchGeometry?
    private var collapsedFrame: NSRect = .zero
    private var expandedFrame: NSRect = .zero
    private var isExpanded = false
    private var cancellables = Set<AnyCancellable>()
    /// Never torn down: the controller lives for the lifetime of the app.
    private var clickMonitor: Any?

    /// How far the black pill extends past each side of the physical notch,
    /// giving us visible area to draw the session count and usage meters into.
    private let wingWidth: CGFloat = 98

    init(monitor: SessionMonitor, summaries: SummaryStore, approvals: ApprovalStore, usage: UsageStore) {
        self.monitor = monitor
        self.summaries = summaries
        self.approvals = approvals
        self.usage = usage
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
        window?.orderFrontRegardless()
    }

    private func configureFrames() {
        guard let geometry = ScreenLocator.notchGeometry() else { return }
        self.geometry = geometry

        let screen = geometry.screen
        let collapsedWidth = geometry.hasNotch ? geometry.notchWidth + wingWidth * 2 : 252
        let collapsedHeight = max(geometry.notchHeight, 32)
        let expandedWidth: CGFloat = 440
        let expandedHeight: CGFloat = 560

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

        window?.setFrame(collapsedFrame, display: false)
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

        // An approval blocks a session until answered, so surface it without
        // waiting for the user to hover the notch.
        approvals.$pending
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] hasPending in
                guard let self else { return }
                if hasPending {
                    self.uiState.selectedSessionId = nil
                    self.uiState.isPinned = true
                } else {
                    self.uiState.isPinned = false
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
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        }
    }
}
