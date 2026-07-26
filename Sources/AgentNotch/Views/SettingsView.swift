import SwiftUI

/// One pane of the preferences window. The tab bar itself is an `NSToolbar`
/// driven by `SettingsWindowController`, not a SwiftUI `TabView`: only a real
/// toolbar gets the centered, titled preference look, and it lets the window
/// resize itself to whichever pane is showing.
enum SettingsPane: String, CaseIterable, Identifiable {
    /// 並び順は macOS の慣習に合わせる。一般が先頭、めったに触らない技術寄りの
    /// ものが末尾。ポーリング間隔が「メニューバー」と「承認」の間にあると、
    /// 日常的に開くペインの導線を分断してしまう。
    case general, display, menuBar, approval, dataRefresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .display: return "表示"
        case .menuBar: return "メニューバー"
        case .approval: return "承認"
        // 「更新」だけだとソフトウェアアップデートに読める。ここで設定するのは
        // ファイルとレート制限をどれくらいの間隔で読み直すか。
        case .dataRefresh: return "データ更新"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "macwindow"
        case .menuBar: return "menubar.rectangle"
        case .approval: return "checkmark.shield"
        case .dataRefresh: return "arrow.clockwise"
        }
    }

    /// Fallback for the rare case where the hosted view reports no intrinsic
    /// height; the window measures the real content first.
    var fallbackHeight: CGFloat {
        switch self {
        case .general: return 340
        case .display: return 620
        case .menuBar: return 300
        case .approval: return 300
        case .dataRefresh: return 500
        }
    }

    @ViewBuilder
    func view(settings: AppSettings, updates: UpdateStore) -> some View {
        switch self {
        case .general: GeneralSettingsView(settings: settings, updates: updates)
        case .display: DisplaySettingsView(settings: settings)
        case .menuBar: MenuBarSettingsView(settings: settings)
        case .approval: ApprovalSettingsView(settings: settings)
        case .dataRefresh: RefreshSettingsView(settings: settings)
        }
    }
}

// MARK: - 表示

private struct DisplaySettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("ノッチパネルを表示", isOn: $settings.showNotchPanel)
                Toggle("ホバーで展開", isOn: $settings.expandOnHover)
                Toggle("折りたたみ時に使用量メーターを表示", isOn: $settings.showUsageInNotch)
                    .disabled(!settings.usageEnabled)
            } footer: {
                Text(settings.expandOnHover
                     ? "ノッチに触れると自動で開きます。"
                     : "ノッチをクリックしたときだけ開きます。")
                .settingsFootnote()
            }

            Section {
                Toggle("推定コストを表示", isOn: $settings.showCostEstimates)
            } footer: {
                Text("定額プランはトークン単位で課金されないため、表示されるのは同じ処理を従量課金の API で回した場合の換算値です。請求額ではありません。")
                    .settingsFootnote()
            }

            Section {
                DisplayPickerRow(settings: settings)
            } header: {
                Text("表示先")
            } footer: {
                Text("ノッチのない画面ではメニューバーの下に同じ形のピルを描きます。選んだディスプレイを外している間は自動選択に戻り、つなぎ直すと元に戻ります。")
                    .settingsFootnote()
            }

            Section("サイズ") {
                SliderRow(
                    title: "ウィングの幅",
                    value: $settings.wingWidth,
                    range: 60...170,
                    step: 2,
                    format: { "\(Int($0)) pt" }
                )
                SliderRow(
                    title: "パネルの幅",
                    value: $settings.panelWidth,
                    range: 340...680,
                    step: 10,
                    format: { "\(Int($0)) pt" }
                )
                SliderRow(
                    title: "パネルの高さ",
                    value: $settings.panelHeight,
                    range: 360...820,
                    step: 10,
                    format: { "\(Int($0)) pt" }
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - メニューバー

private struct MenuBarSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("メニューバーにアイコンを表示", isOn: $settings.showStatusItem)
                Toggle("セッション数をアイコンの横に表示", isOn: $settings.showSessionCountInMenuBar)
                    .disabled(!settings.showStatusItem)
                Toggle("メニューに使用量を表示", isOn: $settings.showUsageInMenu)
                    .disabled(!settings.showStatusItem || !settings.usageEnabled)
                Toggle("メニューにセッションのタイトルとトークン数を表示", isOn: $settings.showSessionTitlesInMenu)
                    .disabled(!settings.showStatusItem)
            } footer: {
                if !settings.showStatusItem && !settings.showNotchPanel {
                    Label(
                        "アイコンとノッチの両方を隠すと、設定を開き直す手段がなくなります。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                } else {
                    Text("アイコンを隠してもノッチパネルからセッションを確認できます。")
                        .settingsFootnote()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - データ更新

private struct RefreshSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                SliderRow(
                    title: "セッション一覧",
                    value: $settings.sessionPollInterval,
                    range: 0.5...10,
                    step: 0.5,
                    format: Self.seconds
                )
                SliderRow(
                    title: "セッションの要約",
                    value: $settings.summaryPollInterval,
                    range: 1...30,
                    step: 0.5,
                    format: Self.seconds
                )
                SliderRow(
                    title: "トランスクリプト",
                    value: $settings.transcriptPollInterval,
                    range: 0.5...10,
                    step: 0.5,
                    format: Self.seconds
                )
            } header: {
                Text("ポーリング間隔")
            } footer: {
                Text("間隔を短くすると反応が速くなりますが、ディスク読み込みが増えます。")
                    .settingsFootnote()
            }

            Section("使用量") {
                Toggle("使用量を取得する", isOn: $settings.usageEnabled)
                // Floor of a minute: the endpoint is shared with the CLI and
                // answers 429 when polled harder than that.
                SliderRow(
                    title: "取得間隔",
                    value: $settings.usageRefreshInterval,
                    range: 60...1800,
                    step: 60,
                    format: { "\(Int($0 / 60)) 分" }
                )
                .disabled(!settings.usageEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) 秒" : String(format: "%.1f 秒", value)
    }
}

// MARK: - 承認

private struct ApprovalSettingsView: View {
    @ObservedObject var settings: AppSettings

    /// A short, non-alarming subset of the system sounds.
    private static let sounds = ["Ping", "Glass", "Pop", "Submarine", "Tink", "Funk"]

    var body: some View {
        Form {
            Section {
                Toggle("承認待ちになったらパネルを自動で開く", isOn: $settings.autoOpenOnApproval)
                Toggle("Dock アイコンで注意を促す", isOn: $settings.bounceOnApproval)
                Toggle("サウンドを鳴らす", isOn: $settings.playSoundOnApproval)
                Picker("サウンド", selection: $settings.approvalSoundName) {
                    ForEach(Self.sounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(!settings.playSoundOnApproval)
                .onChange(of: settings.approvalSoundName) { _, name in
                    NSSound(named: name)?.play()
                }
            } footer: {
                Text("自動で開かない設定でも、承認待ちの間はノッチに「承認」と表示されます。")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 一般

private struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateStore
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            } footer: {
                Text("開発中のビルドでは、署名の状態によって登録に失敗することがあります。")
                    .settingsFootnote()
            }

            Section {
                HStack(spacing: 10) {
                    AgentMarkView(activity: .idle, size: 28, introduces: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AgentNotch")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Claude Code のセッションをノッチから見る")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)

                LabeledContent("バージョン") {
                    Text(Self.version).foregroundStyle(.secondary)
                }
                LabeledContent("承認ソケット") {
                    Text("~/Library/Application Support/AgentNotch/approvals.sock")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            UpdateSection(settings: settings, updates: updates)

            Section {
                HStack {
                    Button("設定をリセット") { isConfirmingReset = true }
                    Spacer()
                    Button("AgentNotch を終了") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "すべての設定を初期値に戻しますか？",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("リセット", role: .destructive) { settings.resetToDefaults() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

/// Lists the connected displays. The list is rebuilt on screen-parameter
/// changes so plugging a monitor in while the window is open offers it right
/// away, and a stored display that is currently unplugged keeps its slot rather
/// than leaving the picker blank.
private struct DisplayPickerRow: View {
    @ObservedObject var settings: AppSettings
    @State private var displays: [DisplayOption] = ScreenLocator.availableDisplays()

    var body: some View {
        Picker("表示するディスプレイ", selection: $settings.preferredScreenID) {
            Text("自動（ノッチのある画面）")
                .tag(ScreenLocator.automaticIdentifier)
            Divider()
            ForEach(displays) { display in
                Text(label(for: display)).tag(display.id)
            }
            if isStoredDisplayMissing {
                Divider()
                Text("接続されていないディスプレイ").tag(settings.preferredScreenID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = ScreenLocator.availableDisplays()
        }
    }

    private var isStoredDisplayMissing: Bool {
        settings.preferredScreenID != ScreenLocator.automaticIdentifier
            && !displays.contains { $0.id == settings.preferredScreenID }
    }

    /// Two identical monitors report the same name, so fall back to the point
    /// size to tell them apart — but only then, since it reads as clutter.
    private func label(for display: DisplayOption) -> String {
        var text = display.name
        if displays.filter({ $0.name == display.name }).count > 1 {
            text += "（\(Int(display.size.width))×\(Int(display.size.height))）"
        }
        if display.hasNotch { text += " · ノッチあり" }
        return text
    }
}

// MARK: - ソフトウェア更新

/// The update controls, kept out of `GeneralSettingsView` because the phase
/// machine needs more branching than the rest of that pane put together.
///
/// Checking happens on its own; downloading and installing never do. Replacing
/// the running app is not something to discover after the fact, and the
/// archive is unsigned by Apple — the only thing vouching for it is our own
/// signature, so the user gets to decide when to trust it.
private struct UpdateSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle("自動的に更新を確認", isOn: $settings.automaticUpdateChecks)
                .disabled(updates.installBlock != nil)

            HStack(spacing: 8) {
                status
                Spacer(minLength: 12)
                action
            }
        } header: {
            Text("ソフトウェア更新")
        } footer: {
            Text(footnote).settingsFootnote()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.phase {
        case .idle:
            Text(lastChecked).foregroundStyle(.secondary)
        case .checking:
            busy("確認中…")
        case .upToDate:
            Text("最新です").foregroundStyle(.secondary)
        case .available(let update):
            HStack(spacing: 6) {
                Text("バージョン \(update.version.description) があります")
                if let page = update.pageURL {
                    Button("内容") { openURL(page) }
                        .buttonStyle(.link)
                }
            }
        case .downloading:
            busy("ダウンロード中…")
        case .verifying:
            busy("署名を検証中…")
        case .staged(let update):
            Text("\(update.version.description) の準備ができました")
        case .installing:
            busy("再起動しています…")
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(message)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch updates.phase {
        case .checking, .downloading, .verifying, .installing:
            EmptyView()
        case .available:
            Button("ダウンロード") { updates.download() }
                .disabled(updates.installBlock != nil)
        case .staged:
            Button("再起動して適用") { updates.install() }
                .keyboardShortcut(.defaultAction)
        default:
            Button("更新を確認") { updates.check() }
                .disabled(updates.installBlock != nil)
        }
    }

    private func busy(_ label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private var lastChecked: String {
        guard let date = updates.lastCheckedAt else { return "まだ確認していません" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        return "最終確認: \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var footnote: String {
        if let block = updates.installBlock { return block }
        return """
        非公開リポジトリのため、確認と取得には gh コマンドのログインを使います。\
        配布物は署名を検証してから入れ替えます。
        """
    }
}

// MARK: - Shared pieces

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

private extension View {
    func settingsFootnote() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}
