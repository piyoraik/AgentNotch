import SwiftUI

/// One pane of the preferences window. The tab bar itself is an `NSToolbar`
/// driven by `SettingsWindowController`, not a SwiftUI `TabView`: only a real
/// toolbar gets the centered, titled preference look, and it lets the window
/// resize itself to whichever pane is showing.
enum SettingsPane: String, CaseIterable, Identifiable {
    case display, menuBar, refresh, approval, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: return "表示"
        case .menuBar: return "メニューバー"
        case .refresh: return "更新"
        case .approval: return "承認"
        case .general: return "一般"
        }
    }

    var symbol: String {
        switch self {
        case .display: return "macwindow"
        case .menuBar: return "menubar.rectangle"
        case .refresh: return "arrow.clockwise"
        case .approval: return "checkmark.shield"
        case .general: return "gearshape"
        }
    }

    /// Fallback for the rare case where the hosted view reports no intrinsic
    /// height; the window measures the real content first.
    var fallbackHeight: CGFloat {
        switch self {
        case .display: return 540
        case .menuBar: return 300
        case .refresh: return 500
        case .approval: return 300
        case .general: return 340
        }
    }

    @ViewBuilder
    func view(settings: AppSettings) -> some View {
        switch self {
        case .display: DisplaySettingsView(settings: settings)
        case .menuBar: MenuBarSettingsView(settings: settings)
        case .refresh: RefreshSettingsView(settings: settings)
        case .approval: ApprovalSettingsView(settings: settings)
        case .general: GeneralSettingsView(settings: settings)
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

// MARK: - 更新

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
                    ClaudeMarkView(activity: .idle, size: 28, introduces: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ClaudeNotch")
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
                    Text("~/Library/Application Support/ClaudeNotch/approvals.sock")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    Button("設定をリセット") { isConfirmingReset = true }
                    Spacer()
                    Button("ClaudeNotch を終了") { NSApp.terminate(nil) }
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
