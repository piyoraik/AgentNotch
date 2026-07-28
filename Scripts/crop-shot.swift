// ドキュメント用スクリーンショットの切り出し。
//
//   swift Scripts/crop-shot.swift <入力> <出力> auto [--pad 24] [--max-width 1600]
//   swift Scripts/crop-shot.swift <入力> <出力> <x> <y> <w> <h> [--max-width 1600]
//
// auto はノッチのパネル用。画面上端に接した暗い矩形（明るい壁紙の中の黒）を
// 中央から探して切り出す。通常のウィンドウは座標で指定する。
//
// ImageMagick も PIL も入っていないため CoreGraphics で行う。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Fail: Error { let message: String }

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadImage(_ path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw Fail(message: "読めない: \(path)")
    }
    return image
}

/// 8bit RGBA に描き直して素のバイト列にする。元の色空間や配置に依存しないため。
func rgbaBytes(_ image: CGImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = bytes.withUnsafeMutableBytes({ raw -> CGContext? in
        CGContext(data: raw.baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }) else {
        throw Fail(message: "ビットマップを作れない")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (bytes, width, height)
}

/// 上端に接した暗い矩形を中央から探す。y は画像座標（上が 0）。
func detectPanel(_ image: CGImage, threshold: Int) throws -> CGRect {
    let (bytes, width, height) = try rgbaBytes(image)

    func isDark(_ x: Int, _ y: Int) -> Bool {
        let i = (y * width + x) * 4
        let luma = (Int(bytes[i]) * 299 + Int(bytes[i + 1]) * 587 + Int(bytes[i + 2]) * 114) / 1000
        return luma < threshold
    }

    let centerX = width / 2

    func darkRun(at y: Int) -> (left: Int, right: Int)? {
        guard isDark(centerX, y) else { return nil }
        var left = centerX
        while left > 0 && isDark(left - 1, y) { left -= 1 }
        var right = centerX
        while right < width - 1 && isDark(right + 1, y) { right += 1 }
        return (left, right)
    }

    // 1 行だけ見て決めない。文字やカードの縁を跨ぐ行では途切れ、
    // 壁紙が暗い行では逆に画面幅まで伸びるため、多数の行を取って最頻値にする。
    // メニューバーは画面幅いっぱいに暗いので、その行はここで落ちる。
    var tally: [String: (count: Int, left: Int, right: Int)] = [:]
    let lower = Int(Double(width) * 0.15)
    let upper = Int(Double(width) * 0.85)
    for y in stride(from: max(1, height / 20), to: Int(Double(height) * 0.7), by: 8) {
        guard let run = darkRun(at: y) else { continue }
        let span = run.right - run.left
        guard span > lower, span < upper else { continue }
        let key = "\(run.left),\(run.right)"
        tally[key, default: (0, run.left, run.right)].count += 1
    }
    guard let best = tally.values.max(by: { $0.count < $1.count }), best.count >= 3 else {
        throw Fail(message: "暗いパネルが中央に見つからない（座標で指定する）")
    }
    let left = best.left
    let right = best.right

    // 下端は列 1 本では測れない。パネルの下に別の暗いウィンドウがあると
    // そこまで伸び、中央の列は文字で途切れるため、幅方向に散らした点の
    // 「暗い割合」で行ごとに判定して、上から連続している間だけ下ろす。
    let samples = stride(from: left + 8, to: right - 8, by: max(1, (right - left) / 32)).map { $0 }
    func rowIsPanel(_ y: Int) -> Bool {
        let dark = samples.reduce(0) { $0 + (isDark($1, y) ? 1 : 0) }
        return Double(dark) / Double(samples.count) >= 0.6
    }
    // メーターのバーや文字が並ぶ帯は「暗い行」にならないので、
    // 途切れたら少し先まで見て、パネルが再開していれば跨ぐ。
    // パネルの下端より先には再開が無いのでそこで止まる。
    let startY = max(1, height / 20)
    var bottom = startY
    var y = startY
    while y < height {
        if rowIsPanel(y) {
            bottom = y
            y += 1
            continue
        }
        var lookahead = y + 1
        var resumed = false
        while lookahead < min(height, y + 200) {
            if rowIsPanel(lookahead) { resumed = true; break }
            lookahead += 1
        }
        if resumed { y = lookahead } else { break }
    }

    return CGRect(x: CGFloat(left), y: 0, width: CGFloat(right - left + 1), height: CGFloat(bottom + 1))
}

func write(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw Fail(message: "書き出せない: \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Fail(message: "書き出しに失敗: \(path)") }
}

func scaled(_ image: CGImage, maxWidth: Int) throws -> CGImage {
    guard image.width > maxWidth else { return image }
    let width = maxWidth
    let height = Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded())
    guard let context = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Fail(message: "縮小用のビットマップを作れない")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let out = context.makeImage() else { throw Fail(message: "縮小に失敗") }
    return out
}

// MARK: - 引数

var args = Array(CommandLine.arguments.dropFirst())
var pad = 0
var maxWidth = 0

func takeOption(_ name: String) -> Int? {
    guard let index = args.firstIndex(of: name) else { return nil }
    guard index + 1 < args.count, let value = Int(args[index + 1]) else {
        die("\(name) に数値が要る")
    }
    args.removeSubrange(index...(index + 1))
    return value
}

pad = takeOption("--pad") ?? 0
maxWidth = takeOption("--max-width") ?? 0
let threshold = takeOption("--threshold") ?? 25

guard args.count >= 3 else {
    die("usage: crop-shot.swift <入力> <出力> auto|<x> <y> <w> <h> [--pad N] [--max-width N]")
}

let inputPath = args[0]
let outputPath = args[1]

do {
    let image = try loadImage(inputPath)
    var rect: CGRect

    if args[2] == "auto" {
        rect = try detectPanel(image, threshold: threshold)
        rect = rect.insetBy(dx: CGFloat(-pad), dy: CGFloat(-pad))
        // 上端は画面の縁なので広げない。
        if rect.minY < 0 { rect = CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.maxY) }
    } else {
        guard args.count >= 6,
              let x = Int(args[2]), let y = Int(args[3]),
              let w = Int(args[4]), let h = Int(args[5]) else {
            die("座標は x y w h の 4 つ")
        }
        rect = CGRect(x: x, y: y, width: w, height: h).insetBy(dx: CGFloat(-pad), dy: CGFloat(-pad))
    }

    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    rect = rect.intersection(bounds).integral
    guard !rect.isEmpty else { die("切り出す範囲が画像の外にある") }

    guard var cropped = image.cropping(to: rect) else { die("切り出しに失敗") }
    if maxWidth > 0 { cropped = try scaled(cropped, maxWidth: maxWidth) }
    try write(cropped, to: outputPath)

    print("\(outputPath) — \(Int(rect.width))x\(Int(rect.height)) を切り出し (\(cropped.width)x\(cropped.height) で保存)")
} catch let error as Fail {
    die(error.message)
} catch {
    die("\(error)")
}
