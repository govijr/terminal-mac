import Foundation
import Virtualization
import TerminalMacCore
import Darwin

/// gvproxy's PID and the VM-side socket path, cleaned up when the runtime process exits for any reason
/// (`exit` after guest shutdown, `stop --force`, errors); gvproxy removes its own socket and PID file.
private nonisolated(unsafe) var gvproxyPID: pid_t = 0
private nonisolated(unsafe) var vmSocketPath: UnsafeMutablePointer<CChar>?

/// User-space networking: a bundled gvproxy (containers/gvisor-tap-vsock) does DHCP, DNS and NAT for the guest in user
/// space, with DNS resolved by the host's own resolver. macOS's shared-networking DNS relay at the NAT gateway stops
/// answering under VPN and proxy apps that run in TUN mode, which leaves a NAT guest without name resolution; this
/// mode keeps the guest online there. The guest sees a 192.168.127.0/24 network: gateway and DNS at 192.168.127.1,
/// the guest itself at 192.168.127.2, and the host reachable at 192.168.127.254 (host.containers.internal).
@MainActor
final class UserNetwork {
    /// gvproxy hands this MAC a static lease for 192.168.127.2.
    static let guestMACAddress = "5a:94:ef:e4:0c:ee"
    let attachment: VZFileHandleNetworkDeviceAttachment
    private let process: Process
    private let sockets: [URL]

    /// gvproxy ships next to the host executable inside TerminalMac.app.
    static func executable(near executableURL: URL) -> URL {
        executableURL.deletingLastPathComponent().appendingPathComponent("gvproxy")
    }
    static func isBundled(near executableURL: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: executable(near: executableURL).path)
    }
    static let missing = "User-space networking needs the bundled gvproxy. Run scripts/fetch-gvproxy.sh then scripts/build.sh, or use NAT: terminal-mac network NAME --nat"

    init(directory: URL, executable: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure(Self.missing) }
        let pidFile = directory.appendingPathComponent("gvproxy.pid")
        Self.stopStale(pidFile: pidFile)
        let socketDirectory = try Self.socketDirectory(for: directory)
        let remote = socketDirectory.appendingPathComponent("gvproxy.sock")
        let local = socketDirectory.appendingPathComponent("vm.sock")
        sockets = [remote, local]
        unlink(remote.path); unlink(local.path)
        process = Process()
        process.executableURL = executable
        // No SSH forward (gvproxy would otherwise listen on 127.0.0.1:2222); gvproxy's own messages go to runtime.log.
        process.arguments = ["-listen-vfkit", "unixgram://" + remote.path, "-ssh-port", "-1", "-mtu", "1500", "-pid-file", pidFile.path]
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var listening = false
        for _ in 0..<100 where process.isRunning {
            if FileManager.default.fileExists(atPath: remote.path) { listening = true; break }
            usleep(50_000)
        }
        guard listening else { process.terminate(); throw Failure("gvproxy did not start. Details: \(directory.appendingPathComponent("runtime.log").path)") }
        do {
            let fd = try Self.attach(local: local.path, remote: remote.path)
            attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
        } catch { process.terminate(); throw error }
        gvproxyPID = process.processIdentifier
        vmSocketPath = strdup(local.path)
        atexit {
            if gvproxyPID > 0 { kill(gvproxyPID, SIGTERM) }
            if let vmSocketPath { unlink(vmSocketPath) }
        }
    }
    deinit {
        if process.isRunning { process.terminate() }
        gvproxyPID = 0
        for socket in sockets { unlink(socket.path) }
        if let vmSocketPath { free(vmSocketPath) }
        vmSocketPath = nil
    }
    /// A runtime killed outright leaves its gvproxy behind, holding the socket; the next boot replaces it.
    private static func stopStale(pidFile: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer).hasSuffix("/gvproxy") else { return }
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 { usleep(50_000) }
        try? FileManager.default.removeItem(at: pidFile)
    }
    /// Unix socket paths are limited to 103 bytes; long data directories fall back to the user's private temporary directory.
    private static func socketDirectory(for directory: URL) throws -> URL {
        if directory.appendingPathComponent("gvproxy.sock").path.utf8.count < 100 { return directory }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-mac-\(directory.lastPathComponent)", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return fallback
    }
    /// A datagram socket bound to `local` and connected to gvproxy's listener, the way vfkit connects: each
    /// datagram is one Ethernet frame. Virtualization requires exactly this kind of socket.
    private static func attach(local: String, remote: String) throws -> Int32 {
        func address(_ path: String) throws -> sockaddr_un {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else { throw Failure("Socket path is too long: \(path)") }
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
            }
            return address
        }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure("Cannot create the guest network socket") }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        var localAddress = try address(local)
        guard withUnsafePointer(to: &localAddress, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }) == 0 else {
            let reason = String(cString: strerror(errno)); close(fd); throw Failure("Cannot bind \(local): \(reason)")
        }
        var remoteAddress = try address(remote)
        guard withUnsafePointer(to: &remoteAddress, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) } }) == 0 else {
            let reason = String(cString: strerror(errno)); close(fd); throw Failure("Cannot connect to gvproxy: \(reason)")
        }
        var sendBuffer: Int32 = 1 << 20, receiveBuffer: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        // gvproxy learns the VM side's address from the first datagram; vfkit sends this marker.
        _ = "VFKT".withCString { write(fd, $0, 4) }
        return fd
    }
}
