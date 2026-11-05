import Foundation

/// One torrent as reported by the daemon's `List` response (`src/protocol.rs`).
struct TorrentSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let infoHash: String
    let state: String
    let progressBytes: UInt64
    let totalBytes: UInt64
    let downloadSpeed: UInt64
    let uploadSpeed: UInt64
    let outputFolder: String
    let error: String?
    let uploadedBytes: UInt64
    let seeders: UInt64
    let leechers: UInt64
    let etaSeconds: UInt64?
    let files: [FileSummary]

    enum CodingKeys: String, CodingKey {
        case id, name, state, error, files, seeders, leechers
        case infoHash = "info_hash"
        case progressBytes = "progress_bytes"
        case totalBytes = "total_bytes"
        case downloadSpeed = "download_speed"
        case uploadSpeed = "upload_speed"
        case outputFolder = "output_folder"
        case uploadedBytes = "uploaded_bytes"
        case etaSeconds = "eta_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        infoHash = try c.decode(String.self, forKey: .infoHash)
        state = try c.decode(String.self, forKey: .state)
        progressBytes = try c.decode(UInt64.self, forKey: .progressBytes)
        totalBytes = try c.decode(UInt64.self, forKey: .totalBytes)
        downloadSpeed = try c.decode(UInt64.self, forKey: .downloadSpeed)
        uploadSpeed = try c.decode(UInt64.self, forKey: .uploadSpeed)
        outputFolder = try c.decode(String.self, forKey: .outputFolder)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        uploadedBytes = try c.decodeIfPresent(UInt64.self, forKey: .uploadedBytes) ?? 0
        seeders = try c.decodeIfPresent(UInt64.self, forKey: .seeders) ?? 0
        leechers = try c.decodeIfPresent(UInt64.self, forKey: .leechers) ?? 0
        etaSeconds = try c.decodeIfPresent(UInt64.self, forKey: .etaSeconds)
        files = try c.decodeIfPresent([FileSummary].self, forKey: .files) ?? []
    }

    var status: TorrentStatus { TorrentStatus(rawValue: state) ?? .unknown }

    var fraction: Double {
        totalBytes == 0 ? 0 : Double(progressBytes) / Double(totalBytes)
    }

    var isComplete: Bool { totalBytes > 0 && progressBytes >= totalBytes }
    var isPaused: Bool { status == .paused }

    /// Sort key for the ETA column; unknown ETAs sort last.
    var etaSortKey: UInt64 { etaSeconds ?? UInt64.max }

    var folderURL: URL { URL(fileURLWithPath: outputFolder, isDirectory: true) }

    func fileURL(_ file: FileSummary) -> URL {
        folderURL.appendingPathComponent(file.path)
    }

    /// The largest selected file with a video extension, if any.
    var mainVideo: FileSummary? {
        files.filter { $0.isVideo && $0.selected }.max { $0.length < $1.length }
    }

    var selectedBytes: UInt64 {
        files.filter(\.selected).reduce(0) { $0 + $1.length }
    }
}

struct FileSummary: Decodable, Hashable, Sendable {
    let path: String
    let length: UInt64
    let progressBytes: UInt64
    let selected: Bool

    enum CodingKeys: String, CodingKey {
        case path, length, selected
        case progressBytes = "progress_bytes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        length = try c.decode(UInt64.self, forKey: .length)
        progressBytes = try c.decodeIfPresent(UInt64.self, forKey: .progressBytes) ?? 0
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? true
    }

    var name: String { (path as NSString).lastPathComponent }

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "m4v", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "ogv", "3gp",
    ]

    var isVideo: Bool {
        Self.videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    var isComplete: Bool { progressBytes >= length }
}

enum TorrentStatus: String, Sendable {
    case downloading, seeding, paused, initializing, error, unknown

    var label: String {
        switch self {
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .paused: "Paused"
        case .initializing: "Checking"
        case .error: "Error"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .downloading: "arrow.down.circle.fill"
        case .seeding: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .initializing: "circle.dotted"
        case .error: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

enum StatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case downloading = "Downloading"
    case paused = "Paused"
    case done = "Done"

    var id: Self { self }

    func matches(_ torrent: TorrentSummary) -> Bool {
        switch self {
        case .all: true
        case .downloading: torrent.status == .downloading || torrent.status == .initializing
        case .paused: torrent.status == .paused
        case .done: torrent.status == .seeding || torrent.isComplete
        }
    }
}

struct DaemonResponse: Decodable, Sendable {
    let error: String?
    let message: String?
    let torrents: [TorrentSummary]
    let preview: TorrentPreview?
}

/// Metadata of a torrent that has not been added yet (the daemon's `Inspect` reply).
struct TorrentPreview: Decodable, Hashable, Sendable {
    let name: String
    let infoHash: String
    let totalBytes: UInt64
    let files: [FileSummary]

    enum CodingKeys: String, CodingKey {
        case name, files
        case infoHash = "info_hash"
        case totalBytes = "total_bytes"
    }
}
