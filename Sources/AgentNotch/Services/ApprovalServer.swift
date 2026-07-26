import Darwin
import Foundation

/// Listens on a unix socket for PermissionRequest payloads relayed by the
/// bridge helper, and writes back the decision the user made in the notch.
final class ApprovalServer {
    static let socketURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentNotch", isDirectory: true)
        .appendingPathComponent("approvals.sock")

    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "AgentNotch.approval.accept")
    private let connectionQueue = DispatchQueue(label: "AgentNotch.approval.connection", attributes: .concurrent)
    private let handler: @Sendable (ApprovalRequest, @escaping @Sendable (ApprovalDecision) -> Void) -> Void

    init(handler: @escaping @Sendable (ApprovalRequest, @escaping @Sendable (ApprovalDecision) -> Void) -> Void) {
        self.handler = handler
    }

    func start() {
        let path = ApprovalServer.socketURL.path
        try? FileManager.default.createDirectory(
            at: ApprovalServer.socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A socket file left behind by a previous run would block bind().
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                for (index, byte) in pathBytes.enumerated() {
                    dest[index] = CChar(bitPattern: byte)
                }
                dest[pathBytes.count] = 0
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return
        }

        listenFD = fd
        acceptLoop(on: fd)
    }

    func stop() {
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(ApprovalServer.socketURL.path)
    }

    private func acceptLoop(on fd: Int32) {
        acceptQueue.async { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard let self else {
                    close(client)
                    return
                }
                self.connectionQueue.async {
                    self.serve(client: client)
                }
            }
        }
    }

    private func serve(client: Int32) {
        var payload = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !payload.contains(0x0A) {
            let count = recv(client, &chunk, chunk.count, 0)
            if count <= 0 { break }
            payload.append(contentsOf: chunk[0..<count])
        }

        guard let line = payload.split(separator: 0x0A).first,
              let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let request = ApprovalRequest(json: json)
        else {
            ApprovalServer.respond(client: client, decision: .passthrough)
            return
        }

        handler(request) { decision in
            ApprovalServer.respond(client: client, decision: decision)
        }
    }

    private static func respond(client: Int32, decision: ApprovalDecision) {
        defer { close(client) }
        guard decision != .passthrough else { return }

        var data = (try? JSONSerialization.data(withJSONObject: ["behavior": decision.rawValue])) ?? Data()
        data.append(0x0A)
        _ = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return send(client, base, buffer.count, 0)
        }
    }
}
