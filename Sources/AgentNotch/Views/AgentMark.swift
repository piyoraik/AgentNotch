import AppKit
import SwiftUI

/// AgentNotch のブランドカラー。ノッチは常に黒地なので、暗い背景で沈まない値を選ぶ。
///
/// 寒色を通常状態、暖色を注意状態に割り当てている。この対応を崩さない。
/// 「動いている」と「人間の応答を待っている」を色温度だけで見分けられるのが、
/// ノッチのように小さく速く読む UI では効くため。
///
/// これはアプリ自身の色。Claude Code を指すマークやバッジには `ClaudeBrand` を使う。
enum AgentBrand {
    /// ミント。メーターの先端側で、いちばん明るい。
    static let mint = Color(red: 0.373, green: 0.890, blue: 0.812)
    /// 中間のシアン。
    static let sky = Color(red: 0.247, green: 0.749, blue: 0.910)
    /// アズール。メーターの根元側。
    static let azure = Color(red: 0.290, green: 0.486, blue: 1.0)
    /// 承認待ち・警告。寒色の通常状態と衝突しない暖色。
    static let amber = Color(red: 1.0, green: 0.722, blue: 0.302)
    static let ivory = Color(red: 0.945, green: 0.929, blue: 0.898)

    /// 数値やバッジに一色だけ乗せたいときの既定。暗所での可読性でミントを採る。
    static let accent = mint

    static let markGradient = LinearGradient(
        colors: [azure, sky, mint],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
}

/// AgentNotch 自身のマークをベクタで描く Shape。
///
/// 円弧のメーターと瞳を重ねた形。上が開いているのがノッチで、開口部の分だけ
/// 欠けた輪が「見張っている目」に見える。`Design/AgentNotchIcon.svg` と同じ
/// 比率で、比率は外周半径に対する定数として持つ。SVG を直すときはここも合わせる。
///
/// 塗りで閉じたパスとして組む（線ではない）。`MarkLayerView` が `CAShapeLayer`
/// のマスクとして白で塗るため、ストロークだと形が出ない。
struct AgentMark: Shape {
    /// 輪の中心線の半径。外周に対する比。
    var ringRadius: CGFloat = 0.822
    /// 輪の太さ。外周に対する比。
    var ringWidth: CGFloat = 0.355
    /// 中心の瞳の半径。外周に対する比。
    var pupilRadius: CGFloat = 0.316
    /// 輪の開いている角度。真上を中心に欠ける。
    var gap: CGFloat = 84

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let outer = min(rect.width, rect.height) / 2
        guard outer > 0, gap < 360 else { return path }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let mid = outer * ringRadius
        let half = outer * ringWidth / 2
        // 開口部を真上に置く。角度は 0 が右、増える向きが画面上の時計回りなので
        // 真上は -90 度。
        let start = Angle.degrees(-90 + Double(gap) / 2)
        let end = Angle.degrees(-90 + 360 - Double(gap) / 2)

        func point(_ angle: Angle, _ radius: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + radius * cos(angle.radians),
                y: center.y + radius * sin(angle.radians)
            )
        }

        // 外周 → 終端の丸キャップ → 内周を逆向きに → 始端の丸キャップ。
        // 内周を逆向きに辿るので nonzero でドーナツの穴が空く。
        // `clockwise: false` が角度の増える向き（画面上の時計回り）。
        path.move(to: point(start, mid + half))
        path.addArc(center: center, radius: mid + half, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(
            center: point(end, mid),
            radius: half,
            startAngle: end,
            endAngle: end + .degrees(180),
            clockwise: false
        )
        path.addArc(center: center, radius: mid - half, startAngle: end, endAngle: start, clockwise: true)
        path.addArc(
            center: point(start, mid),
            radius: half,
            startAngle: start + .degrees(180),
            endAngle: start + .degrees(360),
            clockwise: false
        )
        path.closeSubpath()

        let pupil = outer * pupilRadius
        path.addEllipse(in: CGRect(
            x: center.x - pupil,
            y: center.y - pupil,
            width: pupil * 2,
            height: pupil * 2
        ))
        return path
    }
}

/// AgentNotch 自身を名乗るときのマーク。
///
/// アプリの器にあたるところに出す。ノッチのピル・メニューバー・空の状態・
/// 設定ウィンドウ。**パネルの中で「Claude Code」を名指しているところは
/// `ClaudeMarkView`。** どちらを出すかは「誰を指しているか」で決める。
struct AgentMarkView: View {
    var activity: MarkActivity = .idle
    var size: CGFloat = 14
    var introduces: Bool = false

    var body: some View {
        MarkView(art: .agentRing, activity: activity, size: size, introduces: introduces)
    }
}

extension AgentMark {
    /// メニューバー用の NSImage。テンプレート指定だと macOS 側が色を無視して
    /// 明暗に合わせてくれるので、通常時はテンプレート、動作中だけ着色する。
    static func statusImage(size: CGFloat = 16, busy: Bool) -> NSImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        // 端が切れないよう少しだけ内側に描く。
        let cgPath = AgentMark().path(in: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath
        // **`flipped: true` を外さない。** `AgentMark` は `Shape` なので y が
        // 下向きの前提で組んである。y 上向きのまま描くと開口部が下にきて、
        // アプリアイコンと上下が逆のマークがメニューバーに出る。
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            if busy {
                NSColor(AgentBrand.accent).setFill()
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
