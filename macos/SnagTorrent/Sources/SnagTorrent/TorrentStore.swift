import AppKit
import Foundation
import Observation

/// Live view of the daemon's torrents plus every action the UI can take.
@MainActor
@Observable
final class TorrentStore {
    static let shared = TorrentStore()

    private(set) var torrents: [TorrentSummary] = []
    private(set) var daemonRunning = false
    private(set) var pendingAdds = 0
    private(set) var startingDaemon = false
    var alert: AlertMessage?

    /// The add in progress: metadata being fetched, or a resolved torrent waiting for
    /// the user to pick files. Drives the file-picker sheet.
    enum AddFlow {
        case fetching(source: String)
        case ready(TorrentPreview, source: String, startPaused: Bool)
    }

    private(set) var addFlow: AddFlow?
    private var addQueue: [(source: String, startPaused: Bool)] = []
    private var fetchGeneration = 0

    // View state shared by the table, the toolbar, and the menu commands.
    var filter: StatusFilter = .all
    var searchText = ""
    var sortOrder: [KeyPathComparator<TorrentSummary>] = [KeyPathComparator(\.id)]

    /// Torrents after the status filter, the search, and the current sort.
    var visibleTorrents: [TorrentSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return torrents
            .filter { filter.matches($0) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted(using: sortOrder)
    }

    let client = DaemonClient()
    private var pollTask: Task<Void, Never>?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var totalDownloadSpeed: UInt64 { torrents.reduce(0) { $0 + $1.downloadSpeed } }
    var totalUploadSpeed: UInt64 { torrents.reduce(0) { $0 + $1.uploadSpeed } }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.startDaemon(quietly: true)
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refresh() async {
        do {
            let response = try await client.send(.list)
            torrents = response.torrents
            daemonRunning = true
        } catch let error as DaemonError where error.notRunning {
            torrents = []
            daemonRunning = false
        } catch {
            // Transient failure (for example a timeout); keep the last snapshot.
        }
    }

    func startDaemon(quietly: Bool = false) async {
        startingDaemon = true
        defer { startingDaemon = false }
        do {
            try await client.ensureRunning()
            await refresh()
        } catch {
            daemonRunning = false
            if !quietly { report("Could not start the daemon", error) }
        }
    }

    func stopDaemon() async {
        do {
            _ = try await client.send(.shutdown)
        } catch let error as DaemonError where error.notRunning {
            // Already stopped.
        } catch {
            report("Could not stop the daemon", error)
        }
        torrents = []
        daemonRunning = false
    }

    // MARK: - Torrent actions

    /// Queues a source; each one is resolved (added paused) and then shown in the
    /// file picker before anything downloads.
    func add(_ source: String, paused: Bool = false) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addQueue.append((trimmed, paused))
        processAddQueue()
    }

    private func processAddQueue() {
        guard addFlow == nil, !addQueue.isEmpty else { return }
        let next = addQueue.removeFirst()
        addFlow = .fetching(source: next.source)
        fetchGeneration += 1
        let generation = fetchGeneration
        pendingAdds += 1
        Task {
            defer { pendingAdds -= 1 }
            do {
                try await client.ensureRunning()
                let response = try await client.send(.inspect(source: next.source))
                guard generation == fetchGeneration, case .fetching = addFlow else { return }
                guard let preview = response.preview else {
                    let name = response.torrents.first?.name ?? next.source
                    report("Already in the list", DaemonError("“\(name)” was added before."))
                    finishAdd()
                    return
                }
                addFlow = .ready(preview, source: next.source, startPaused: next.startPaused)
            } catch {
                guard generation == fetchGeneration else { return }
                report("Could not read torrent", error)
                finishAdd()
            }
        }
    }

    /// Confirms the picker: adds the torrent with only `files` (indices) selected.
    func confirmAdd(files: Set<Int>) {
        guard case let .ready(preview, source, startPaused) = addFlow else { return }
        let all = Set(preview.files.indices)
        let onlyFiles: [Int]? = files.isEmpty || files == all ? nil : files.sorted()
        addFlow = nil
        pendingAdds += 1
        Task {
            defer { pendingAdds -= 1 }
            do {
                _ = try await client.send(.add(source: source, paused: startPaused, onlyFiles: onlyFiles))
                await refresh()
            } catch {
                report("Could not add “\(preview.name)”", error)
            }
            processAddQueue()
        }
    }

    /// Cancels the picker; nothing was added, so there is nothing to undo.
    func cancelAdd() {
        guard addFlow != nil else { return }
        fetchGeneration += 1
        finishAdd()
    }

    private func finishAdd() {
        addFlow = nil
        processAddQueue()
    }

    func add(fileURL: URL) {
        add(fileURL.path)
    }

    func togglePause(_ torrent: TorrentSummary) {
        perform("Could not \(torrent.isPaused ? "resume" : "pause") “\(torrent.name)”") {
            torrent.isPaused ? .resume(id: torrent.id) : .pause(id: torrent.id)
        }
    }

    func remove(_ torrent: TorrentSummary, deleteFiles: Bool) {
        perform("Could not remove “\(torrent.name)”") {
            .remove(id: torrent.id, deleteFiles: deleteFiles)
        }
    }

    func revealInFinder(_ torrent: TorrentSummary) {
        let target: URL
        if torrent.files.count == 1, let only = torrent.files.first,
           FileManager.default.fileExists(atPath: torrent.fileURL(only).path) {
            target = torrent.fileURL(only)
        } else {
            target = torrent.folderURL
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// The video file Play would open: the largest video in the torrent, once it exists on disk.
    func playableVideo(_ torrent: TorrentSummary) -> URL? {
        guard let video = torrent.mainVideo else { return nil }
        let url = torrent.fileURL(video)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Opens the torrent's largest video file in the default player, or reveals
    /// the download folder when there is no video on disk yet.
    func play(_ torrent: TorrentSummary) {
        if let url = playableVideo(torrent) {
            NSWorkspace.shared.open(url)
        } else {
            revealInFinder(torrent)
        }
    }

    // MARK: - Helpers

    private func perform(_ failureTitle: String, _ request: @escaping @Sendable () -> DaemonRequest) {
        Task {
            do {
                _ = try await client.send(request())
                await refresh()
            } catch {
                report(failureTitle, error)
            }
        }
    }

    private func report(_ title: String, _ error: Error) {
        alert = AlertMessage(title: title, message: error.localizedDescription)
    }
}
