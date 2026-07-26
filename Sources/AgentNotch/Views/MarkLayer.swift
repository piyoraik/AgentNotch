import AppKit
import SwiftUI

/// どのマークを描くか。
///
/// アプリ自身を指すときは `agentRing`、Claude Code を指すときは `claudeSpark`。
/// **この使い分けを崩さない。** ノッチのピル・メニューバー・空の状態・設定は
/// アプリの器なので `agentRing`、パネルの中で「Claude Code」を名指している
/// ところ（見出しのロックアップ・セッション詳細・使用状況レポート）が
/// `claudeSpark`。監視対象が増えたらここに case を足す。
enum MarkArt: Equatable {
    case agentRing
    case claudeSpark
}

/// マークが伝える状態。
///
/// - `idle` は静止。
/// - `busy` はゆっくり回りながら呼吸する。
/// - `alert` は承認待ち。回転を止めて暖色で速く明滅する。
enum MarkActivity: Equatable { case idle, busy, alert }

/// マークの下地。着色済みのビットマップを 1 枚作って、それを回す。
///
/// 連続アニメーションは SwiftUI ではなく CoreAnimation に載せている。
/// SwiftUI の `repeatForever` はフレームごとにホスティングビュー全体の
/// レイアウトを走らせるため、常時見えているノッチに置くと CPU を 50% 近く
/// 持っていく。レイヤアニメーションならメインスレッドは動かない。
///
/// **マスクを使わない。** 以前は `CAGradientLayer` を形でマスクして
/// `shouldRasterize` で焼いていたが、マスクはラスタライズのキャッシュに
/// 入らないので合成のたびに効く。12pt のマークを常時回した実測で、
/// マスクありが 5.2〜9.2%、先に 1 枚へ潰したものが 0% 台。
/// グラデーションと形を焼いてしまえば、回転はただの画像を回すだけになる。
final class MarkLayerView: NSView {
    private let art: MarkArt
    private let mark = CALayer()
    private var activity: MarkActivity
    /// 最後に焼いた条件。**`layout()` は毎フレーム走る**（SwiftUI 側の再評価や
    /// ホスティングビューのレイアウトに引きずられる）ので、焼き直しをここで
    /// 止める。止めないと焼き付けのほうが高くつく（実測 9.8% → 18.3%）。
    private var built: (size: CGSize, scale: CGFloat, activity: MarkActivity)?

    init(art: MarkArt, activity: MarkActivity) {
        self.art = art
        self.activity = activity
        super.init(frame: .zero)
        // 層をホストするビューは layer を先に差してから wantsLayer を立てる。
        // 順序が逆だと AppKit が自前のレイヤを作って上書きしてしまう。
        layer = CALayer()
        wantsLayer = true
        mark.contentsGravity = .resize
        layer?.addSublayer(mark)
        applyAnimations()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // レイアウト由来の暗黙アニメーションを止める。位置が動くたびに
        // マークがぬるっと追従すると、ノッチの開閉が二重に見える。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        mark.frame = bounds
        if built?.size != bounds.size || built?.scale != scale || built?.activity != activity {
            mark.contentsScale = scale
            mark.contents = MarkBitmap.bake(art: art, colors: colors, fitting: bounds.size, scale: scale)
            built = (bounds.size, scale, activity)
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // 新しい倍率で焼き直す必要があるので layout に任せる。
        needsLayout = true
    }

    func apply(_ activity: MarkActivity) {
        guard activity != self.activity else { return }
        self.activity = activity
        // 色が状態で変わるので焼き直す。
        needsLayout = true
        applyAnimations()
    }

    /// 承認待ちだけは、どちらのマークでも暖色に振る。ブランドの色ではなく
    /// 「人間の応答を待っている」という状態の色なので、マークによらず同じ。
    private var colors: [Color] {
        if activity == .alert {
            return [AgentBrand.amber, .orange]
        }
        switch art {
        case .agentRing:
            return [AgentBrand.azure, AgentBrand.sky, AgentBrand.mint]
        case .claudeSpark:
            return [ClaudeBrand.ember, ClaudeBrand.clay, ClaudeBrand.crail]
        }
    }

    private func applyAnimations() {
        mark.removeAllAnimations()
        switch activity {
        case .idle:
            break
        case .busy:
            mark.add(spin(duration: 9), forKey: "spin")
            mark.add(breathe(to: 1.09, duration: 1.7), forKey: "breathe")
        case .alert:
            mark.add(breathe(to: 1.14, duration: 0.7), forKey: "breathe")
        }
    }

    private func spin(duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = Self.frameRate
        return animation
    }

    private func breathe(to scale: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1
        animation.toValue = scale
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = Self.frameRate
        return animation
    }

    /// 常に出ているノッチで 120fps 相当を回し続ける価値はない。ゆっくりした
    /// 回転と脈動なので、30fps でも動きの質は変わらない。
    private static let frameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
}

/// 着色済みのマークを、描く大きさぴったりのビットマップに焼く。
enum MarkBitmap {
    /// グラデーションの向き。右上（根元）から左下（先端）へ。アイコンの SVG と同じ。
    /// AppKit の角度は反時計回りで、y 上向きの文脈では 225 度が左下を向く。
    private static let gradientAngle: CGFloat = 225

    static func bake(art: MarkArt, colors: [Color], fitting size: CGSize, scale: CGFloat) -> CGImage? {
        let gradient = NSGradient(colors: colors.map { NSColor($0) })
        return bake(fitting: size, scale: scale) { rect in
            switch art {
            case .agentRing:
                gradient?.draw(in: NSBezierPath(cgPath: ringPath(in: rect)), angle: gradientAngle)
            case .claudeSpark:
                gradient?.draw(in: rect, angle: gradientAngle)
                // 元絵の不透明なところだけ残す。これでマークの形に切り抜かれる。
                ClaudeMark.image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            }
        }
    }

    /// `AgentMark` は `Shape` なので y が下向きの前提で組んである。ここは
    /// AppKit の y 上向きの文脈なので、**上下を返さないと開口部が下にくる。**
    /// アイコンは開口部が真上なので、返さないとアプリとアイコンで形が違う。
    private static func ringPath(in rect: NSRect) -> CGPath {
        var flip = CGAffineTransform(translationX: 0, y: rect.height).scaledBy(x: 1, y: -1)
        let path = AgentMark().path(in: rect).cgPath
        return path.copy(using: &flip) ?? path
    }

    /// ピクセル数と論理サイズをずらした `NSBitmapImageRep` に描く。
    /// 描画側は pt で扱えて、出来上がりは実ピクセル数ぴったりになる。
    private static func bake(
        fitting size: CGSize,
        scale: CGFloat,
        _ draw: (NSRect) -> Void
    ) -> CGImage? {
        let wide = Int((size.width * scale).rounded())
        let high = Int((size.height * scale).rounded())
        guard wide > 0, high > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: wide,
                  pixelsHigh: high,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              )
        else { return nil }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// アニメーションするマーク。`AgentMarkView` / `ClaudeMarkView` の実体。
struct MarkView: View {
    let art: MarkArt
    var activity: MarkActivity = .idle
    var size: CGFloat = 14
    /// 起動直後に一度だけ回り込みながら現れる。こちらは一度で終わるので
    /// SwiftUI 側のアニメーションでよい。
    var introduces: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        MarkLayer(art: art, activity: reduceMotion ? .idle : activity)
            .frame(width: size, height: size)
            .scaleEffect(revealed ? 1 : 0.4)
            .rotationEffect(.degrees(revealed ? 0 : -160))
            .opacity(revealed ? 1 : 0)
            .onAppear {
                guard introduces, !reduceMotion else {
                    revealed = true
                    return
                }
                withAnimation(.spring(response: 0.75, dampingFraction: 0.55)) { revealed = true }
            }
            .accessibilityHidden(true)
    }
}

private struct MarkLayer: NSViewRepresentable {
    let art: MarkArt
    let activity: MarkActivity

    func makeNSView(context: Context) -> MarkLayerView {
        MarkLayerView(art: art, activity: activity)
    }

    func updateNSView(_ view: MarkLayerView, context: Context) {
        view.apply(activity)
    }
}
