// リリース成果物に Ed25519 の署名を付けるための道具。
//
//   swift Scripts/signing.swift keygen
//   swift Scripts/signing.swift sign <file>
//   swift Scripts/signing.swift verify <file> <file.sig> <公開鍵 base64>
//
// アプリ側の検証は Sources/AgentNotch/Services/ReleaseSignature.swift。
// 同じ CryptoKit を使うので、片方だけ形式を変えると噛み合わなくなる。
//
// **秘密鍵をリポジトリに入れない。** GitHub 側が乗っ取られても署名を作れない
// ことが、この仕組みが守っている唯一のもの。鍵を一緒に置くと意味がなくなる。
import CryptoKit
import Foundation

let keyPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/agentnotch/release-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyPath, encoding: .utf8) else {
        fail("秘密鍵がない: \(keyPath.path)\n先に `swift Scripts/signing.swift keygen` を実行する。")
    }
    guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else {
        fail("秘密鍵を読めない: \(keyPath.path)")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "keygen":
    if FileManager.default.fileExists(atPath: keyPath.path) {
        // 上書きすると、既に配った版を検証できる鍵が失われる。
        fail("既に鍵がある: \(keyPath.path)\n作り直すと過去のリリースを検証できなくなる。消すなら手で消す。")
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(
        at: keyPath.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyPath)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)

    print("秘密鍵: \(keyPath.path)")
    print("公開鍵: \(key.publicKey.rawRepresentation.base64EncodedString())")
    print("")
    print("公開鍵を ReleaseSignature.swift の publicKeyBase64 に貼る。")

case "sign":
    guard args.count == 2 else { fail("使い方: sign <file>") }
    let file = URL(fileURLWithPath: args[1])
    guard let data = try? Data(contentsOf: file) else { fail("読めない: \(file.path)") }

    let signature = try loadPrivateKey().signature(for: data)
    let out = file.appendingPathExtension("sig")
    try Data((signature.base64EncodedString() + "\n").utf8).write(to: out)
    print(out.path)

case "verify":
    guard args.count == 4 else { fail("使い方: verify <file> <file.sig> <公開鍵 base64>") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { fail("読めない: \(args[1])") }
    guard let sigText = try? String(contentsOf: URL(fileURLWithPath: args[2]), encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines))
    else { fail("署名を読めない: \(args[2])") }
    guard let rawKey = Data(base64Encoded: args[3]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    else { fail("公開鍵が不正") }

    if key.isValidSignature(signature, for: data) {
        print("ok")
    } else {
        fail("署名が一致しない")
    }

default:
    fail("使い方: signing.swift keygen | sign <file> | verify <file> <sig> <pubkey>")
}
