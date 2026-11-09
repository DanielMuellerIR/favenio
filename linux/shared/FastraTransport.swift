import Foundation
import Glibc

private func fastraEndpoints() -> [String] {
    let root = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp/fastra-control-\(getuid())"
    var info = stat()
    guard root.hasPrefix("/"), lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return [] }
    return ["org.fastra.Fastra.Development", "org.fastra.Fastra.NativeCandidate"].map { root + "/" + $0 + ".control.v1.sock" }
}
private func connectFastra(_ path: String, deadline: TimeInterval) -> Int32? {
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue) | Int32(SOCK_NONBLOCK.rawValue), 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if result != 0 && (errno != EINPROGRESS || !waitFastra(fd, event: Int16(POLLOUT), deadline: deadline)) { close(fd); return nil }
    var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { close(fd); return nil }
    var credentials = [Int32](repeating: 0, count: 3); size = 12
    let verified = credentials.withUnsafeMutableBytes { getsockopt(fd, SOL_SOCKET, SO_PEERCRED, $0.baseAddress, &size) }
    guard verified == 0, size == 12, UInt32(bitPattern: credentials[1]) == getuid() else { close(fd); return nil }
    return fd
}
private func waitFastra(_ fd: Int32, event: Int16, deadline: TimeInterval) -> Bool {
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: event, revents: 0)
        let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 10_000)))
        if result < 0 && errno == EINTR { continue }
        return result > 0 && descriptor.revents & event != 0
    }
}
private func fastraTransfer(_ fd: Int32, bytes: inout [UInt8], writing: Bool, deadline: TimeInterval) -> Bool {
    var offset = 0
    while offset < bytes.count {
        guard waitFastra(fd, event: Int16(writing ? POLLOUT : POLLIN), deadline: deadline) else { return false }
        let remaining = bytes.count - offset
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            if writing { return Glibc.send(fd, buffer.baseAddress!.advanced(by: offset), remaining, Int32(MSG_NOSIGNAL)) }
            return recv(fd, buffer.baseAddress!.advanced(by: offset), remaining, 0)
        }
        if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
        guard count > 0 else { return false }
        offset += count
    }
    return true
}

enum SearchControlClient {
    static func available(_ name: String) -> Bool {
        for endpoint in fastraEndpoints() {
            if let fd = connectFastra(endpoint, deadline: ProcessInfo.processInfo.systemUptime + 0.1) { close(fd); return true }
        }
        return false
    }
    static func send(_ data: Data, name: String, timeout: TimeInterval) -> Data? {
        guard data.count <= 262_144, timeout > 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var connected: Int32?
        for endpoint in fastraEndpoints() { if let fd = connectFastra(endpoint, deadline: deadline) { connected = fd; break } }
        guard let fd = connected else { return nil }
        defer { close(fd) }
        let count = UInt32(data.count)
        var request = [UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)] + data
        guard fastraTransfer(fd, bytes: &request, writing: true, deadline: deadline) else { return nil }
        var header = [UInt8](repeating: 0, count: 4)
        guard fastraTransfer(fd, bytes: &header, writing: false, deadline: deadline) else { return nil }
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= 1_048_576 else { return nil }
        var reply = [UInt8](repeating: 0, count: size)
        return fastraTransfer(fd, bytes: &reply, writing: false, deadline: deadline) ? Data(reply) : nil
    }
    static func launch() -> Bool {
        if available("") { return true }
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? NSHomeDirectory() + "/.local/share"
        for file in [data + "/applications/fastra.desktop", "/usr/share/applications/fastra.desktop"] where FileManager.default.fileExists(atPath: file) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/gio"); process.arguments = ["launch", file]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); return true } catch { return false }
        }
        return false
    }
}
