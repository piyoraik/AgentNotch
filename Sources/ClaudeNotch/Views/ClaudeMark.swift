import AppKit
import SwiftUI

/// Claude のブランドカラー。ノッチは常に黒地なので、暗い背景で沈まない値を選ぶ。
enum ClaudeBrand {
    /// Claude のオレンジ。
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    /// 少し沈んだ影側の色。グラデーションの終端に使う。
    static let crail = Color(red: 0.741, green: 0.376, blue: 0.259)
    /// 明るい側。ハイライトとグローに使う。
    static let ember = Color(red: 0.965, green: 0.639, blue: 0.478)
    static let ivory = Color(red: 0.945, green: 0.929, blue: 0.898)

    static let markGradient = LinearGradient(
        colors: [ember, clay, crail],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Claude のスパークマークをベクタで描く Shape。
///
/// 公式のアセットファイルは同梱していないため、放射する花弁の集合として
/// 再現している。公式の SVG/PDF が手元にあるなら、この Shape を差し替えれば
/// 呼び出し側は変更しなくてよい。
struct ClaudeMark: Shape {
    /// 放射する花弁の本数。
    var rayCount: Int = 11
    /// 半径に対する花弁の根元の幅。ここが太いほど中心の塊が大きくなる。
    var baseWidth: CGFloat = 0.26
    /// 半径に対する花弁の先端の幅。根元より細いと先すぼまりになる。
    var tipWidth: CGFloat = 0.055
    /// 0 で全部同じ長さ、1 で本来のマークに近い長短が付く。
    var lengthVariation: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        guard rayCount > 0, radius > 0 else { return path }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseHalf = radius * baseWidth / 2
        let tipHalf = radius * tipWidth / 2

        for index in 0..<rayCount {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(rayCount)
            let outer = radius * Self.length(at: index, variation: lengthVariation)
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            let across = CGVector(dx: -direction.dy, dy: direction.dx)

            func point(_ along: CGFloat, _ offset: CGFloat) -> CGPoint {
                CGPoint(
                    x: center.x + direction.dx * along + across.dx * offset,
                    y: center.y + direction.dy * along + across.dy * offset
                )
            }

            // 根元は中心に集めてしまう。全部の花弁が重なるので芯が塗り潰され、
            // 別途コアの円を足さずに済む。
            let shoulder = max(outer - tipHalf, 0)
            // 側面は直線ではなく、根元寄りで少し膨らませてから絞る。
            // 直線のままだと針のようになってマークに見えない。
            let waistAlong = outer * 0.3
            let waistHalf = baseHalf * 0.82

            path.move(to: point(0, baseHalf))
            path.addQuadCurve(to: point(shoulder, tipHalf), control: point(waistAlong, waistHalf))
            // 先端は円弧ではなく二次曲線で丸める。Path の巻き方向の解釈に
            // 依存しないので、拡大しても形が崩れない。
            path.addQuadCurve(
                to: point(shoulder, -tipHalf),
                control: point(outer + tipHalf * 0.8, 0)
            )
            path.addQuadCurve(to: point(0, -baseHalf), control: point(waistAlong, -waistHalf))
            path.closeSubpath()
        }
        return path
    }

    /// 黄金角で長短を振る。本数を変えても隣り合う花弁が同じ長さにならない。
    private static func length(at index: Int, variation: CGFloat) -> CGFloat {
        let wave = abs(sin(Double(index) * 2.39996))
        return 1 - variation * 0.16 * CGFloat(wave)
    }
}

/// アニメーションするマーク。セッションの状態を形で伝える。
///
/// - `idle` は静止。
/// - `busy` はゆっくり回りながら呼吸する。
/// - `alert` は承認待ち。回転を止めて速く明滅する。
///
/// 連続アニメーションは SwiftUI ではなく CoreAnimation に任せている
/// （`MarkLayerView`）。SwiftUI の `repeatForever` はフレームごとに
/// ホスティングビュー全体のレイアウトを走らせるため、常時見えている
/// ノッチに置くと CPU を 50% 近く持っていく。レイヤアニメーションなら
/// メインスレッドは動かない。
struct ClaudeMarkView: View {
    enum Activity: Equatable { case idle, busy, alert }

    var activity: Activity = .idle
    var size: CGFloat = 14
    /// 起動直後に一度だけ回り込みながら現れる。こちらは一度で終わるので
    /// SwiftUI 側のアニメーションでよい。
    var introduces: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        MarkLayer(activity: reduceMotion ? .idle : activity)
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
    let activity: ClaudeMarkView.Activity

    func makeNSView(context: Context) -> MarkLayerView {
        MarkLayerView(activity: activity)
    }

    func updateNSView(_ view: MarkLayerView, context: Context) {
        view.apply(activity)
    }
}

/// マークを CAGradientLayer + マスクで描き、回転と脈動をレイヤに載せる。
final class MarkLayerView: NSView {
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()
    private var activity: ClaudeMarkView.Activity

    init(activity: ClaudeMarkView.Activity) {
        self.activity = activity
        super.init(frame: .zero)
        // 層をホストするビューは layer を先に差してから wantsLayer を立てる。
        // 順序が逆だと AppKit が自前のレイヤを作って上書きしてしまう。
        layer = CALayer()
        wantsLayer = true
        mask.fillColor = NSColor.white.cgColor
        gradient.mask = mask
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)
        applyColors()
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
        gradient.frame = bounds
        mask.frame = bounds
        mask.path = ClaudeMark().path(in: bounds).cgPath
        // マスク付きグラデーションは合成が重い。一度ビットマップに焼いて
        // おけば、回転や拡縮はその画像を動かすだけで済む。
        gradient.rasterizationScale = window?.backingScaleFactor ?? 2
        gradient.shouldRasterize = true
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        gradient.rasterizationScale = window?.backingScaleFactor ?? 2
    }

    func apply(_ activity: ClaudeMarkView.Activity) {
        guard activity != self.activity else { return }
        self.activity = activity
        applyColors()
        applyAnimations()
    }

    private func applyColors() {
        let colors: [Color] = activity == .alert
            ? [.yellow, .orange]
            : [ClaudeBrand.ember, ClaudeBrand.clay, ClaudeBrand.crail]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = colors.map { NSColor($0).cgColor }
        CATransaction.commit()
    }

    private func applyAnimations() {
        gradient.removeAllAnimations()
        switch activity {
        case .idle:
            break
        case .busy:
            gradient.add(spin(duration: 9), forKey: "spin")
            gradient.add(breathe(to: 1.09, duration: 1.7), forKey: "breathe")
        case .alert:
            gradient.add(breathe(to: 1.14, duration: 0.7), forKey: "breathe")
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

/// マーク + ワードマーク。設定ウィンドウやパネルの見出しに置く。
struct ClaudeLockup: View {
    var title: String = "Claude Code"
    var subtitle: String?
    var markSize: CGFloat = 18
    var titleSize: CGFloat = 13
    var activity: ClaudeMarkView.Activity = .idle
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

extension ClaudeMark {
    /// メニューバー用の NSImage。テンプレート指定だと macOS 側が色を無視して
    /// 明暗に合わせてくれるので、通常時はテンプレート、動作中だけ着色する。
    static func statusImage(size: CGFloat = 16, busy: Bool) -> NSImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        // 端が切れないよう少しだけ内側に描く。
        let cgPath = ClaudeMark().path(in: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            if busy {
                NSColor(ClaudeBrand.clay).setFill()
            } else {
                NSColor.black.setFill()
            }
            NSBezierPath(cgPath: cgPath).fill()
            return true
        }
        image.isTemplate = !busy
        return image
    }
}
