import SwiftUI

/// アプリ全体で使うアニメーションの定数。個々のビューで duration を
/// 決め打ちすると開閉のタイミングがずれるので、ここに集約する。
enum Motion {
    /// ノッチの開閉。`NotchWindowController` のウィンドウアニメーションと
    /// 体感を合わせてある。
    static let expand = Animation.spring(response: 0.38, dampingFraction: 0.78)
    /// 画面の切り替え（一覧 ↔ 詳細 ↔ 承認）。
    static let navigate = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// 数値やバッジなど小さな変化。
    static let quick = Animation.spring(response: 0.28, dampingFraction: 0.7)
    /// 行が順に現れるときの 1 行あたりの遅延。
    static let stagger = 0.045

    /// ドリルダウンの向きに合わせた出入り。
    static func drill(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

/// 生きているセッションを示す点。動作中は輪が広がって消える。
///
/// `ClaudeMarkView` と同じ理由で、繰り返しは CoreAnimation に載せている。
/// 一覧に何行も並ぶので、1 行あたりのコストがそのまま効いてくる。
struct PulsingDot: View {
    var isActive: Bool
    var size: CGFloat = 7
    var color: Color = .green

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulseLayer(isActive: isActive && !reduceMotion, color: color)
            // 輪が広がる分の余白を確保する。点そのものは中央の size ぶん。
            .frame(width: size * 2.6, height: size * 2.6)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct PulseLayer: NSViewRepresentable {
    let isActive: Bool
    let color: Color

    func makeNSView(context: Context) -> PulseDotView {
        PulseDotView(isActive: isActive, color: NSColor(color))
    }

    func updateNSView(_ view: PulseDotView, context: Context) {
        view.apply(isActive: isActive, color: NSColor(color))
    }
}

final class PulseDotView: NSView {
    private let dot = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var isActive: Bool
    private var color: NSColor

    init(isActive: Bool, color: NSColor) {
        self.isActive = isActive
        self.color = color
        super.init(frame: .zero)
        // 層をホストするビューは layer を先に差してから wantsLayer を立てる。
        // 順序が逆だと AppKit が自前のレイヤを作って上書きしてしまう。
        layer = CALayer()
        wantsLayer = true
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 1.2
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
        applyColors()
        applyAnimations()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 外枠は輪の広がりぶん大きい。点はその中央に、元の直径で描く。
        let diameter = min(bounds.width, bounds.height) / 2.6
        let core = CGRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        for shape in [dot, ring] {
            shape.frame = core
            shape.path = CGPath(ellipseIn: CGRect(origin: .zero, size: core.size), transform: nil)
            // 焼き付けておくと、毎フレームの再合成が画像の変形だけになる。
            shape.rasterizationScale = window?.backingScaleFactor ?? 2
            shape.shouldRasterize = true
        }
        // 影のパスを教えないと、拡縮のたびに輪郭から計算し直される。
        dot.shadowPath = dot.path
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        dot.rasterizationScale = scale
        ring.rasterizationScale = scale
    }

    func apply(isActive: Bool, color: NSColor) {
        guard isActive != self.isActive || color != self.color else { return }
        self.isActive = isActive
        self.color = color
        applyColors()
        applyAnimations()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.fillColor = isActive ? color.cgColor : NSColor.white.withAlphaComponent(0.3).cgColor
        ring.strokeColor = color.cgColor
        ring.opacity = 0
        dot.shadowColor = color.cgColor
        dot.shadowOpacity = isActive ? 0.7 : 0
        dot.shadowRadius = 2.5
        CATransaction.commit()
    }

    private func applyAnimations() {
        dot.removeAllAnimations()
        ring.removeAllAnimations()
        guard isActive else { return }

        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1
        breathe.toValue = 1.15
        breathe.duration = 1.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.preferredFrameRateRange = Self.frameRate
        dot.add(breathe, forKey: "breathe")

        let group = CAAnimationGroup()
        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = 1
        expand.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0
        group.animations = [expand, fade]
        group.duration = 1.6
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.preferredFrameRateRange = Self.frameRate
        ring.add(group, forKey: "ripple")
    }

    /// 一覧にいくつも並ぶ点なので、フレームレートは抑えめにする。
    private static let frameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
}

/// 表示されたときに下からすっと入る。一覧の行に連番を渡すと順に現れる。
private struct StaggeredAppear: ViewModifier {
    let index: Int
    let offset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : offset)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .onAppear {
                guard !reduceMotion else {
                    shown = true
                    return
                }
                withAnimation(
                    .spring(response: 0.42, dampingFraction: 0.8)
                        .delay(Double(index) * Motion.stagger)
                ) { shown = true }
            }
    }
}

/// 押した瞬間に縮む。ノッチのボタンは面積が小さいので、押せたことが
/// 分かる手応えを付ける。
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// ホバーで持ち上がる行。
private struct HoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .brightness(hovering ? 0.06 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func staggeredAppear(index: Int, offset: CGFloat = 8) -> some View {
        modifier(StaggeredAppear(index: index, offset: offset))
    }

    func hoverLift() -> some View {
        modifier(HoverLift())
    }

    /// 数字が変わったときにスロットのように送る。macOS 14 以降のみ。
    func rollingNumber() -> some View {
        contentTransition(.numericText())
            .monospacedDigit()
    }
}
