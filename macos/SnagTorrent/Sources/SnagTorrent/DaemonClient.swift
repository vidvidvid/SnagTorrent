import Foundation

/// Requests understood by the daemon; mirrors `Request` in `src/protocol.rs`
/// (serde's externally tagged enum encoding).
enum DaemonRequest: Sendable {
    case ping
    case list
    case add(source: String, paused: Bool, onlyFiles: [Int]?)
    case inspect(source: String)
    case pause(id: Int)
    case resume(id: Int)
    case remove(id: Int, deleteFiles: Bool)
    case setFiles(id: Int, files: [Int])
    case status
    case configure(pauseWhenDone: Bool?)
    case streamUrl(id: Int, file: Int)
    case shutdown

    var json: Any {
        switch self {
        case .ping: return "Ping"
        case .list: return "List"
        case .status: return "Status"
        case .shutdown: return "Shutdown"
        case let .configure(pauseWhenDone):
            var fields: [String: Any] = [:]
            if let pauseWhenDone { fields["pause_when_done"] = pauseWhenDone }
            return ["Configure": fields]
        case let .streamUrl(id, file): return ["StreamUrl": ["id": id, "file": file]]
        case let .add(source, paused, onlyFiles):
            var add: [String: Any] = ["source": source, "paused": paused, "initial_peers": [String]()]
            if let onlyFiles { add["only_files"] = onlyFiles }
            return ["Add": add]
        case let .inspect(source): return ["Inspect": ["source": source]]
        case let .pause(id): return ["Pause": ["id": id]]
        case let .resume(id): return ["Resume": ["id": id]]
        case let .remove(id, deleteFiles): return ["Remove": ["id": id, "delete_files": deleteFiles]]
        case let .setFiles(id, files): return ["SetFiles": ["id": id, "files": files]]
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .add, .inspect: 130
        default: 15
        }
    }
}

struct DaemonError: LocalizedError, Sendable {
    let message: String
    let notRunning: Bool

    init(_ message: String, notRunning: Bool = false) {
        self.message = message
        self.notRunning = notRunning
    }

    var errorDescription: String? { message }
}

/// Talks to the SnagTorrent daemon over its user-only Unix socket, the same way
/// the `snag` CLI does (`src/client.rs`), and starts the daemon when needed.
final class DaemonClient: Sendable {
    static let maxResponseBytes = 8 * 1024 * 1024

    let stateDirectory: URL
    let socketPath: String
    private let queue = DispatchQueue(label: "io.github.vidvidvid.SnagTorrent.socket", qos: .userInitiated)

    init() {
        let environment = ProcessInfo.processInfo.environment
        if let home = environment["SNAG_HOME"], !home.isEmpty {
            stateDirectory = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            stateDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SnagTorrent", isDirectory: true)
        }
        socketPath = stateDirectory.appendingPathComponent("control.sock").path
    }

    var logURL: URL { stateDirectory.appendingPathComponent("daemon.log") }

    /// Location of the `snag` executable: bundled with the app, else a cargo install.
    static var snagExecutable: URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "snag") {
            candidates.append(bundled)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".cargo/bin/snag"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/snag"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/snag"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func send(_ request: DaemonRequest) async throws -> DaemonResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.exchange(request) })
            }
        }
    }

    /// Blocking variant for the quit path, where waiting on an async reply would
    /// deadlock the main thread. Fails fast when the daemon is not running.
    func sendSynchronously(_ request: DaemonRequest) throws -> DaemonResponse {
        try exchange(request)
    }

    func isRunning() async -> Bool {
        (try? await send(.ping)) != nil
    }

    /// Starts the daemon via `snag start` (which detaches it with its own session)
    /// and waits until it answers pings.
    func ensureRunning() async throws {
        if await isRunning() { return }
        try runSnag(["start"])
        try await waitUntilRunning()
    }

    /// The configured download folder (`config.json`), or the daemon's default.
    var downloadDirectory: URL {
        let config = stateDirectory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: config),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = object["download_dir"] as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/SnagTorrent", isDirectory: true)
    }

    /// Stops the daemon, records the new folder, and starts it again. The folder
    /// can only change at startup, so this is the one way to switch it.
    func restart(downloadDirectory: URL) async throws {
        if await isRunning() {
            _ = try await send(.shutdown)
            for _ in 0..<100 {
                if !(await isRunning()) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if await isRunning() {
                throw DaemonError("The daemon did not stop; try again.")
            }
        }
        try runSnag(["start", "--download-dir", downloadDirectory.path])
        try await waitUntilRunning()
    }

    private func runSnag(_ arguments: [String]) throws {
        guard let executable = Self.snagExecutable else {
            throw DaemonError("Could not find the snag executable. Install it with `cargo install --path .`.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DaemonError(text.isEmpty ? "The daemon failed to start." : text.replacingOccurrences(of: "snag: ", with: ""))
        }
    }

    private func waitUntilRunning() async throws {
        for _ in 0..<50 {
            if await isRunning() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DaemonError("The daemon did not become ready; check \(logURL.path).")
    }

    // MARK: - Socket I/O

    private func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError("Could not create a socket.") }
        defer { close(fd) }

        var timeout = timeval(tv_sec: Int(request.timeout), tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw DaemonError("State directory path is too long for a local socket: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw DaemonError("SnagTorrent is not running.", notRunning: true)
        }

        var payload = try JSONSerialization.data(withJSONObject: request.json, options: [.fragmentsAllowed])
        payload.append(0x0A)
        try payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw DaemonError("Could not send the request to the daemon.") }
                offset += written
            }
        }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                throw DaemonError(errno == EAGAIN || errno == EWOULDBLOCK
                    ? "Timed out talking to the SnagTorrent daemon."
                    : "Could not read the daemon response.")
            }
            if count == 0 { break }
            response.append(chunk, count: count)
            if response.count > Self.maxResponseBytes {
                throw DaemonError("Daemon response is too large.")
            }
        }

        let decoded: DaemonResponse
        do {
            decoded = try JSONDecoder().decode(DaemonResponse.self, from: response)
        } catch {
            throw DaemonError("Daemon returned an invalid response.")
        }
        if let error = decoded.error {
            throw DaemonError(error)
        }
        return decoded
    }
}
