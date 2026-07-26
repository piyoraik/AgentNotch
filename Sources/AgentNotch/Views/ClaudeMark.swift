import AppKit
import SwiftUI

/// Claude のブランドカラー。**AgentNotch 自身の色ではない。**
/// Claude Code を指すマークとバッジにだけ使う。アプリの色は `AgentBrand`。
enum ClaudeBrand {
    /// Claude のオレンジ。
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    /// 少し沈んだ影側の色。グラデーションの終端に使う。
    static let crail = Color(red: 0.741, green: 0.376, blue: 0.259)
    /// 明るい側。ハイライトとグローに使う。
    static let ember = Color(red: 0.965, green: 0.639, blue: 0.478)
}

/// Claude Code のマーク。Claude.app が同梱している公式のトレイアイコン
/// （`TrayIconTemplate`）をそのまま持ってきたもの。
///
/// 以前は花弁を並べた `Shape` で近似していたが、自前で描き起こしたものは
/// 形が違う上に出自が怪しいため、公式アセットに置き換えた。
/// `Resources/Assets.xcassets/ClaudeMark.imageset` がその実体で、
/// アルファだけを使う（テンプレート）ので好きな色に着色できる。
///
/// アプリアイコンの `.icns` ではなくトレイ用を選んでいるのは、`.icns` が
/// 角丸の下地込みのタイルで、12pt のグリフやメニューバーのテンプレートに
/// すると塗り潰した四角になってしまうため。
///
/// **アセットは 72px の 1 枚だけ持つ（`@2x` / `@3x` を並べない）。**
/// macOS は `@3x` を読まないので 24/48/72 の 3 枚を入れても 48px までしか
/// 出てこず、空の状態の 34pt（2x で 68px）が拡大になる。いちばん大きい 1 枚を
/// 1x として持たせておけば、どのサイズでも縮小方向にしかならない。
enum ClaudeMark {
    /// アセットカタログの公式マーク。テンプレート指定なのでアルファだけが効く。
    /// 着色は `MarkBitmap.bake` がアルファで抜きながらやる。
    static let image: NSImage = NSImage(named: "ClaudeMark") ?? NSImage()
}

/// Claude Code を指すアニメーションつきマーク。
///
/// 出すのはパネルの中で Claude Code を名指しているところだけ（見出しの
/// ロックアップ・セッション詳細・使用状況レポート）。ノッチのピルと
/// メニューバーはアプリの器なので `AgentMarkView`。
struct ClaudeMarkView: View {
    var activity: MarkActivity = .idle
    var size: CGFloat = 14
    var introduces: Bool = false

    var body: some View {
        MarkView(art: .claudeSpark, activity: activity, size: size, introduces: introduces)
    }
}

/// マーク + ワードマーク。パネルの見出しに置く。
///
/// 見出しは監視している対象（Claude Code）で、アプリ名ではない。マークも
/// 対象のものを出す。監視対象が増えたら `art` ごと差し替える。
struct AppLockup: View {
    var title: String = "Claude Code"
    var subtitle: String?
    var markSize: CGFloat = 18
    var titleSize: CGFloat = 13
    var activity: MarkActivity = .idle
    var foreground: Color = .white

    var body: some View {
        HStack(spacing: 7) {
            ClaudeMarkView(activity: activity, size: markSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(foreground)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: titleSize - 3))
                        .foregroundStyle(foreground.opacity(0.5))
                }
            }
        }
    }
}
