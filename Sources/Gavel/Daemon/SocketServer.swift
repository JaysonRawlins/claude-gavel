import Foundation

/// Listens on a Unix domain socket for hook events.
///
/// Each hook shim connects, sends a JSON payload, and (for PreToolUse)
/// waits for a JSON response. The server handles connections concurrently
/// using GCD, so multiple agents can send events simultaneously.
final class SocketServer {
    private let socketPath: String
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.gavel.socket", qos: .userInitiated, attributes: .concurrent)
    private var isRunning = false

    var onEvent: ((Data, ((Data) -> Void)?) -> Void)?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        // Clean up stale socket
        unlink(socketPath)

        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw GavelError.socketCreationFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw GavelError.socketPathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fileDescriptor, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fileDescriptor)
            throw GavelError.bindFailed(errno: errno)
        }

        // Restrict socket permissions
        chmod(socketPath, 0o600)

        guard listen(fileDescriptor, 32) == 0 else {
            close(fileDescriptor)
            throw GavelError.listenFailed(errno: errno)
        }

        isRunning = true
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        isRunning = false
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(fileDescriptor, sockPtr, &clientLen)
                }
            }

            guard clientFd >= 0 else {
                if !isRunning { break }
                continue
            }

            // Handle each connection concurrently
            queue.async { [weak self] in
                self?.handleConnection(fd: clientFd)
            }
        }
    }

    private func handleConnection(fd: Int32) {
        defer { close(fd) }

        // Prevent SIGPIPE on this socket if client disconnects during write
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Set read timeout (2 seconds)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read all data
        var data = Data()
        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let bytesRead = read(fd, buf, bufSize)
            if bytesRead <= 0 { break }
            data.append(buf, count: bytesRead)
            // If we got less than buffer size, likely done
            if bytesRead < bufSize { break }
        }

        guard !data.isEmpty else { return }

        // For PreToolUse hooks, we need to send a response back.
        // The handler determines whether to respond based on hook type.
        onEvent?(data) { responseData in
            _ = responseData.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, responseData.count)
            }
        }
    }
}

enum GavelError: Error, LocalizedError {
    case socketCreationFailed(errno: Int32)
    case socketPathTooLong
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e): return "Failed to create socket: \(String(cString: strerror(e)))"
        case .socketPathTooLong: return "Socket path exceeds maximum length"
        case .bindFailed(let e): return "Failed to bind socket: \(String(cString: strerror(e)))"
        case .listenFailed(let e): return "Failed to listen on socket: \(String(cString: strerror(e)))"
        }
    }
}
