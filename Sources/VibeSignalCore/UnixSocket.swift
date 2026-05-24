import Darwin
import Foundation

public enum VibeSignalError: Error, LocalizedError {
    case socketPathTooLong(String)
    case socketAlreadyRunning(String)
    case posix(String, Int32)
    case emptyPayload
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            return "Unix socket path is too long: \(path)"
        case .socketAlreadyRunning(let path):
            return "A Vibe Signal hub is already listening at \(path)"
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .emptyPayload:
            return "No event payload was received"
        case .invalidPayload(let detail):
            return "Invalid event payload: \(detail)"
        }
    }

    public var isSocketOwnershipConflict: Bool {
        switch self {
        case .socketAlreadyRunning:
            return true
        case .posix(let operation, let code):
            return operation == "bind" && code == EADDRINUSE
        default:
            return false
        }
    }
}

private enum UnixSocketAddress {
    static func withSockAddr<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < maxPathLength else {
            throw VibeSignalError.socketPathTooLong(path)
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<maxPathLength {
                    buffer[index] = 0
                }
                for (index, byte) in pathBytes.enumerated() {
                    buffer[index] = CChar(bitPattern: byte)
                }
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, length)
            }
        }
    }
}

public enum UnixSocketClient {
    public static func send(event: SignalEvent, to socketURL: URL = VibeSignalPaths().socketURL) throws {
        let data = try SignalJSON.encode(event) + Data([0x0A])
        try send(data: data, to: socketURL)
    }

    public static func canConnect(to socketURL: URL = VibeSignalPaths().socketURL) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { Darwin.close(fd) }

        do {
            return try UnixSocketAddress.withSockAddr(path: socketURL.path) { address, length in
                Darwin.connect(fd, address, length) == 0
            }
        } catch {
            return false
        }
    }

    public static func send(data: Data, to socketURL: URL = VibeSignalPaths().socketURL) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VibeSignalError.posix("socket", errno)
        }
        defer { Darwin.close(fd) }
        setNoSigPipe(fd: fd)

        try UnixSocketAddress.withSockAddr(path: socketURL.path) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                throw VibeSignalError.posix("connect", errno)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var written = 0
            while written < data.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: written),
                    data.count - written
                )
                if result > 0 {
                    written += result
                } else if result == -1 && errno == EINTR {
                    continue
                } else {
                    throw VibeSignalError.posix("write", errno)
                }
            }
        }
    }

    private static func setNoSigPipe(fd: Int32) {
        var enabled: Int32 = 1
        withUnsafePointer(to: &enabled) { pointer in
            _ = Darwin.setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
    }
}

public final class SignalHubServer {
    private let socketURL: URL
    private let maxPayloadBytes: Int
    private let queue = DispatchQueue(label: "VibeSignal.SignalHubServer")
    private let clientQueue = DispatchQueue(label: "VibeSignal.SignalHubServer.Clients", attributes: .concurrent)
    private let clientSemaphore: DispatchSemaphore
    private let onEvent: (SignalEvent) -> Void
    private var serverFD: Int32 = -1
    private var ownsSocket = false

    public init(
        socketURL: URL = VibeSignalPaths().socketURL,
        maxPayloadBytes: Int = 1_048_576,
        maxConcurrentClients: Int = 16,
        onEvent: @escaping (SignalEvent) -> Void
    ) {
        self.socketURL = socketURL
        self.maxPayloadBytes = maxPayloadBytes
        self.clientSemaphore = DispatchSemaphore(value: maxConcurrentClients)
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    public func start() throws {
        if FileManager.default.fileExists(atPath: socketURL.path) {
            if UnixSocketClient.canConnect(to: socketURL) {
                throw VibeSignalError.socketAlreadyRunning(socketURL.path)
            }
            Darwin.unlink(socketURL.path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VibeSignalError.posix("socket", errno)
        }

        var didBind = false
        do {
            try UnixSocketAddress.withSockAddr(path: socketURL.path) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else {
                    throw VibeSignalError.posix("bind", errno)
                }
            }
            didBind = true

            guard Darwin.listen(fd, 64) == 0 else {
                throw VibeSignalError.posix("listen", errno)
            }

            Darwin.chmod(socketURL.path, S_IRUSR | S_IWUSR)
            serverFD = fd
            ownsSocket = true
            queue.async { [weak self] in
                self?.acceptLoop(fd: fd)
            }
        } catch {
            Darwin.close(fd)
            if didBind {
                Darwin.unlink(socketURL.path)
            }
            throw error
        }
    }

    public func stop() {
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        if ownsSocket {
            Darwin.unlink(socketURL.path)
            ownsSocket = false
        }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD >= 0 {
                if clientSemaphore.wait(timeout: .now()) == .success {
                    clientQueue.async { [weak self] in
                        defer { self?.clientSemaphore.signal() }
                        self?.handleClient(fd: clientFD)
                    }
                } else {
                    Darwin.close(clientFD)
                }
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.close(fd) }
        setReadTimeout(fd: fd)

        do {
            let data = try readAll(fd: fd)
            let events = try decodeEvents(from: data)
            for event in events {
                onEvent(event)
            }
        } catch {
            return
        }
    }

    private func readAll(fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= maxPayloadBytes else {
                    throw VibeSignalError.invalidPayload("payload exceeds \(maxPayloadBytes) bytes")
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw VibeSignalError.posix("read", errno)
            }
        }

        guard !data.isEmpty else {
            throw VibeSignalError.emptyPayload
        }

        return data
    }

    private func decodeEvents(from data: Data) throws -> [SignalEvent] {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw VibeSignalError.emptyPayload
        }

        if text.hasPrefix("[") {
            return try SignalJSON.decode([SignalEvent].self, from: Data(text.utf8))
        }

        let lines = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if lines.count <= 1 {
            return [try SignalJSON.decode(SignalEvent.self, from: Data(text.utf8))]
        }

        return try lines.map { line in
            try SignalJSON.decode(SignalEvent.self, from: Data(line.utf8))
        }
    }

    private func setReadTimeout(fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = Darwin.setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

}
