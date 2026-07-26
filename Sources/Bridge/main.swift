import Darwin
import Foundation

// Invoked by Claude Code as a PermissionRequest hook. Forwards the request to
// a running ClaudeNotch over a unix socket and relays the user's decision.
//
// Every failure path exits 0 with no stdout: that reads as "no decision", so
// Claude Code falls back to its own terminal prompt. A hook that hangs or
// errors loudly would wedge every session on the machine.

let socketPath = NSString(string: "~/Library/Application Support/ClaudeNotch/approvals.sock")
    .expandingTildeInPath

/// Seconds to wait for the user to answer in the notch before handing the
/// decision back to the terminal.
let responseTimeout = 120

func failOpen() -> Never {
    exit(0)
}

func emit(behavior: String) -> Never {
    let payload: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": behavior],
        ],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { failOpen() }
    FileHandle.standardOutput.write(data)
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty else { failOpen() }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { failOpen() }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)

let pathBytes = Array(socketPath.utf8)
let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
guard pathBytes.count < pathCapacity else {
    close(fd)
    failOpen()
}
withUnsafeMutablePointer(to: &address.sun_path) { tuple in
    tuple.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dest in
        for (index, byte) in pathBytes.enumerated() {
            dest[index] = CChar(bitPattern: byte)
        }
        dest[pathBytes.count] = 0
    }
}

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    close(fd)
    failOpen()
}

var timeout = timeval(tv_sec: responseTimeout, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

var request = input
request.append(0x0A)
let written: Int = request.withUnsafeBytes { buffer in
    guard let base = buffer.baseAddress else { return -1 }
    return send(fd, base, buffer.count, 0)
}
guard written == request.count else {
    close(fd)
    failOpen()
}

var response = Data()
var chunk = [UInt8](repeating: 0, count: 1024)
while !response.contains(0x0A) {
    let count = recv(fd, &chunk, chunk.count, 0)
    if count <= 0 { break }
    response.append(contentsOf: chunk[0..<count])
}
close(fd)

guard let line = response.split(separator: 0x0A).first,
      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
      let behavior = object["behavior"] as? String,
      behavior == "allow" || behavior == "deny"
else {
    failOpen()
}

emit(behavior: behavior)
