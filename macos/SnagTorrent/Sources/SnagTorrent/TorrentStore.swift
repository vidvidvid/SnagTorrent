import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications

/// Live view of the daemon's torrents plus every action the UI can take.
@MainActor
@Observable
final class TorrentStore {
    static let shared = TorrentStore()

    private(set) var torrents: [TorrentSummary] = []
    private(set) var daemonRunning = false
    private(set) var pendingAdds = 0
    private(set) var startingDaemon = false
    private(set) var downloadDirectory: URL
    private(set) var changingDownloadDirectory = false
    private(set) var pauseWhenDone = true
    private(set) var streamPort: UInt16 = 0
    private(set) var lastStreamURL: URL?
    var alert: AlertMessage?

    /// Selected rows (torrent ids) and whether the details inspector is open.
    var selection: Set<Int> = []
    var showInspector = false

    var selectedTorrent: TorrentSummary? {
        torrents.first { selection.contains($0.id) }
    }

    var selectedTorrents: [TorrentSummary] {
        torrents.filter { selection.contains($0.id) }
    }

    var activeDownloads: Int {
        torrents.filter { $0.status == .downloading }.count
    }

    // App-side preferences.
    static let notifyWhenDoneKey = "notifyWhenDone"
    static let stopDaemonOnQuitKey = "stopDaemonOnQuit"

    var notifyWhenDone: Bool {
        get { UserDefaults.standard.object(forKey: Self.notifyWhenDoneKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.notifyWhenDoneKey) }
    }

    var stopDaemonOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: Self.stopDaemonOnQuitKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.stopDaemonOnQuitKey) }
    }

    /// Ids seen while still downloading, so a later complete state means "just finished".
    private var incompleteIDs: Set<Int> = []

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

    init() {
        downloadDirectory = client.downloadDirectory
    }

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
            let wasRunning = daemonRunning
            torrents = response.torrents
            daemonRunning = true
            trackCompletions(response.torrents)
            if !wasRunning { await refreshStatus() }
        } catch let error as DaemonError where error.notRunning {
            torrents = []
            daemonRunning = false
        } catch {
            // Transient failure (for example a timeout); keep the last snapshot.
        }
        NSApp.dockTile.badgeLabel = activeDownloads > 0 ? "\(activeDownloads)" : nil
    }

    func refreshStatus() async {
        guard let status = try? await client.send(.status).status else { return }
        pauseWhenDone = status.pauseWhenDone
        streamPort = status.streamPort
        downloadDirectory = URL(fileURLWithPath: status.downloadDir, isDirectory: true)
    }

    func setPauseWhenDone(_ on: Bool) async {
        do {
            if let status = try await client.send(.configure(pauseWhenDone: on)).status {
                pauseWhenDone = status.pauseWhenDone
            }
        } catch {
            report("Could not change the setting", error)
        }
    }

    private func trackCompletions(_ torrents: [TorrentSummary]) {
        for torrent in torrents {
            if torrent.isComplete {
                if incompleteIDs.remove(torrent.id) != nil, notifyWhenDone {
                    notifyCompleted(torrent)
                }
            } else {
                incompleteIDs.insert(torrent.id)
            }
        }
        incompleteIDs = incompleteIDs.intersection(torrents.map(\.id))
    }

    private func notifyCompleted(_ torrent: TorrentSummary) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Download complete"
            content.body = torrent.name
            content.sound = .default
            let request = UNNotificationRequest(identifier: "done-\(torrent.infoHash)", content: content, trigger: nil)
            try? await center.add(request)
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

    /// Switches the download folder for new torrents; restarts the daemon to apply it.
    func changeDownloadDirectory(_ url: URL) async {
        changingDownloadDirectory = true
        defer { changingDownloadDirectory = false }
        do {
            try await client.restart(downloadDirectory: url)
            downloadDirectory = client.downloadDirectory
            await refresh()
        } catch {
            downloadDirectory = client.downloadDirectory
            report("Could not change the download folder", error)
            await refresh()
        }
    }

    func revealDownloadDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([downloadDirectory])
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
        NSApp.dockTile.badgeLabel = nil
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

    /// Pauses every selected torrent if any is running, otherwise resumes them all.
    func togglePause(ids: Set<Int>) {
        let targets = torrents.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let pause = targets.contains { !$0.isPaused }
        for torrent in targets where torrent.isPaused != pause {
            perform("Could not \(pause ? "pause" : "resume") “\(torrent.name)”") {
                pause ? .pause(id: torrent.id) : .resume(id: torrent.id)
            }
        }
    }

    func remove(_ torrent: TorrentSummary, deleteFiles: Bool) {
        selection.remove(torrent.id)
        perform("Could not remove “\(torrent.name)”") {
            .remove(id: torrent.id, deleteFiles: deleteFiles)
        }
    }

    func remove(ids: Set<Int>, deleteFiles: Bool) {
        for torrent in torrents where ids.contains(torrent.id) {
            remove(torrent, deleteFiles: deleteFiles)
        }
    }

    /// Changes which files of an added torrent are wanted.
    func setFiles(_ torrent: TorrentSummary, files: Set<Int>) {
        guard !files.isEmpty else {
            report("Keep at least one file", DaemonError("A torrent needs at least one selected file."))
            return
        }
        perform("Could not change files of “\(torrent.name)”") {
            .setFiles(id: torrent.id, files: files.sorted())
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

    /// The video file Play would open directly: the largest selected video, once it is complete on disk.
    func playableVideo(_ torrent: TorrentSummary) -> URL? {
        guard let video = torrent.mainVideo, video.isComplete else { return nil }
        let url = torrent.fileURL(video)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Opens the torrent's main video: the finished file directly, or a local
    /// stream of it while it is still downloading. Without a video, reveals the folder.
    func play(_ torrent: TorrentSummary) {
        if let url = playableVideo(torrent) {
            NSWorkspace.shared.open(url)
        } else if let video = torrent.mainVideo, let index = torrent.files.firstIndex(of: video) {
            stream(torrent, fileIndex: index)
        } else {
            revealInFinder(torrent)
        }
    }

    /// Opens one file of the torrent: directly when complete, otherwise as a stream.
    func open(_ torrent: TorrentSummary, fileIndex: Int) {
        guard torrent.files.indices.contains(fileIndex) else { return }
        let file = torrent.files[fileIndex]
        let url = torrent.fileURL(file)
        if file.isComplete, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            stream(torrent, fileIndex: fileIndex)
        }
    }

    /// Asks the daemon for a streaming URL and hands it to the default player for
    /// that file type. The daemon fetches pieces in playback order.
    func stream(_ torrent: TorrentSummary, fileIndex: Int) {
        let file = torrent.files[fileIndex]
        Task {
            do {
                if torrent.isPaused {
                    _ = try await client.send(.resume(id: torrent.id))
                }
                if !file.selected {
                    let wanted = Set(torrent.files.indices.filter { torrent.files[$0].selected }).union([fileIndex])
                    _ = try await client.send(.setFiles(id: torrent.id, files: wanted.sorted()))
                }
                guard let text = try await client.send(.streamUrl(id: torrent.id, file: fileIndex)).streamUrl,
                      let url = URL(string: text)
                else { throw DaemonError("The daemon did not return a stream URL.") }
                lastStreamURL = url
                openInPlayer(url, forFileNamed: file.name)
                await refresh()
            } catch {
                report("Could not play “\(file.name)”", error)
            }
        }
    }

    private func openInPlayer(_ url: URL, forFileNamed name: String) {
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .movie
        var candidates: [URL] = []
        if let player = NSWorkspace.shared.urlForApplication(toOpen: type) { candidates.append(player) }
        candidates.append(URL(fileURLWithPath: "/Applications/VLC.app"))
        candidates.append(URL(fileURLWithPath: "/Applications/IINA.app"))
        candidates.append(URL(fileURLWithPath: "/System/Applications/QuickTime Player.app"))
        if let player = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open([url], withApplicationAt: player, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
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
