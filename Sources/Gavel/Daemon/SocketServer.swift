import Foundation

/// Unix-domain-socket listener for hook events — concurrent GCD per-connection, so multiple agents can fire simultaneously.
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
        // Belt-and-suspenders: SO_NOSIGPIPE on per-conn fd covers the daemon, but tests construct SocketServer outside main.swift's signal setup.
        signal(SIGPIPE, SIG_IGN)

        // Single-instance guard: without this, second daemon unlinks+binds and silently steals the path — split-brain across two rule sets.
        if Self.probeAlive(socketPath: socketPath) {
            throw GavelError.daemonAlreadyRunning(path: socketPath)
        }

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

        chmod(socketPath, 0o600)

        guard listen(fileDescriptor, GavelConstants.socketListenBacklog) == 0 else {
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

            queue.async { [weak self] in
                self?.handleConnection(fd: clientFd)
            }
        }
    }

    /// True iff a peer is `accept()`-ing on `socketPath`. Errno semantics: ENOENT/ECONNREFUSED → false; anything else → fail-closed *true* so an EPERM quirk can't clobber a live daemon.
    static func probeAlive(socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() { dest[i] = byte }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        switch errno {
        case ENOENT, ECONNREFUSED: return false
        default: return true
        }
    }

    private func handleConnection(fd: Int32) {
        gavelLog("[socket] enter fd=\(fd)")
        var bytesWritten = 0
        defer {
            gavelLog("[socket] exit fd=\(fd) wroteBytes=\(bytesWritten)")
            close(fd)
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: GavelConstants.socketReadTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        let bufSize = GavelConstants.socketBufferSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let bytesRead = read(fd, buf, bufSize)
            if bytesRead <= 0 { break }
            data.append(buf, count: bytesRead)

            if bytesRead < bufSize { break }
        }

        // Empty payload = client connected but sent nothing (or read timed out). Failing silently makes the hook see EOF → "invalid response" → Claude cancels parallel siblings. Send explicit fail-closed JSON so the cascade is diagnosable.
        guard !data.isEmpty else {
            gavelLog("[socket] empty payload fd=\(fd) — sending fail-closed")
            let errMsg = #"{"verdict":"block","reason":"Gavel: empty hook payload (read timeout — daemon worker may be starved under burst load)"}"#
            let errData = Data(errMsg.utf8)
            let written = errData.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, errData.count)
            }
            if written > 0 { bytesWritten = written }
            return
        }

        onEvent?(data) { responseData in
            let written = responseData.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, responseData.count)
            }
            if written > 0 { bytesWritten = written }
        }
    }
}

enum GavelError: Error, LocalizedError {
    case socketCreationFailed(errno: Int32)
    case socketPathTooLong
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case daemonAlreadyRunning(path: String)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e): return "Failed to create socket: \(String(cString: strerror(e)))"
        case .socketPathTooLong: return "Socket path exceeds maximum length"
        case .bindFailed(let e): return "Failed to bind socket: \(String(cString: strerror(e)))"
        case .listenFailed(let e): return "Failed to listen on socket: \(String(cString: strerror(e)))"
        case .daemonAlreadyRunning(let path): return "Another gavel daemon is already serving \(path)"
        }
    }
}
