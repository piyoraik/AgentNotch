import AppKit
import Combine
import SwiftUI

final class NotchWindowController: NSWindowController {
    private let monitor: SessionMonitor
    private let summaries: SummaryStore
    private let approvals: ApprovalStore
    private let notices: NoticeStore
    private let alerts: AlertCenter
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
        notices: NoticeStore,
        alerts: AlertCenter,
        usage: UsageStore,
        settings: AppSettings = .shared
    ) {
        self.monitor = monitor
        self.summaries = summaries
        self.approvals = approvals
        self.notices = notices
        self.alerts = alerts
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

    /// Opens the panel straight onto the usage report. The menu bar has no
    /// other way into the panel's screens, and this is user-initiated, so it
    /// overrides `showNotchPanel` the same way a pending approval does.
    func showReport() {
        window?.orderFrontRegardless()
        uiState.openReport()
    }

    /// Re-picks the display, and rebuilds the content view when the new screen
    /// wants a different pill (a notch cutout instead of a plain bar, or a
    /// different menu bar height). The hosting view is only recreated when
    /// those numbers actually move, so a resolution change or a resize of the
    /// panel doesn't blow away the open subview.
    private func relocate() {
        let previous = geometry
        configureFrames()
        guard let geometry else { return }
        let changed = previous == nil
            || previous?.hasNotch != geometry.hasNotch
            || previous?.notchWidth != geometry.notchWidth
            || previous?.notchHeight != geometry.notchHeight
        if changed { installContentView() }
    }

    private func configureFrames() {
        guard let geometry = ScreenLocator.notchGeometry(preferring: settings.preferredScreenID) else { return }
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
            notices: notices,
            alerts: alerts,
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
            // `@Published` は willSet で流すので、ここが同期で走ると
            // `uiState.isExpanded` はまだ古い。その状態で `setFrame(display:)`
            // が描画を強制すると、新しい枠に古い側のビューが描かれたうえ、
            // 直前に配信済みの `objectWillChange` がその描画で消費されて
            // 二度と再描画が来ず、ずれたまま固まる。1 ターン遅らせて値を
            // 確定させてから枠を変える。枠 → 中身の順に同じ描画サイクルへ
            // 入るので、ちらつきも出ない。
            .receive(on: DispatchQueue.main)
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

        // 表示先の変更も再起動なしで反映する。`@Published` は willSet で流すため
        // ここで同期に走ると `settings.preferredScreenID` はまだ古い。1 ターン
        // 遅らせてから読み直す。
        settings.$preferredScreenID
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.relocate()
            }
            .store(in: &cancellables)

        // ディスプレイの抜き差し・配置変更・解像度変更。選んだ画面が外れている
        // 間は自動選択に落ち、挿し直せば設定を触らずに戻る。
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.relocate()
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

        // 開閉はアニメーションしない。枠は AppKit、中身は SwiftUI と別々の
        // アニメータになるため、どれだけ曲線を揃えても終わりが完全には一致せず
        // ガタついて見える。即座に切り替えるほうが速く、ぶれもない。
        window.setFrame(target, display: true)

        // `showReport` と承認は、パネル非表示の設定でも窓を前面に出す。畳んだ
        // ところが元に戻す唯一の機会なので、ここで片付ける。これがないと一度
        // メニューからレポートを開いただけで、折りたたんだピルが残り続ける。
        if !expanded, !settings.showNotchPanel, approvals.pending.isEmpty {
            window.orderOut(nil)
        }
    }
}
