import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TorrentStore.self) private var store
    @State private var selection: Set<TorrentSummary.ID> = []
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @State private var showingAddSheet = false
    @State private var pendingDelete: TorrentSummary?
    @State private var isDropTargeted = false

    private var visibleTorrents: [TorrentSummary] { store.visibleTorrents }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            content
            Divider()
            statusBar
        }
        .toolbar { toolbarContent }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search torrents")
        .sheet(isPresented: $showingAddSheet) {
            AddTorrentSheet { source, paused in store.add(source, paused: paused) }
        }
        .alert(item: $store.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { torrent in
            Button("Delete Torrent and Files", role: .destructive) {
                store.remove(torrent, deleteFiles: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { torrent in
            Text("The torrent is removed and its downloaded files in \(torrent.outputFolder) are deleted. This cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .snagShowAddSheet)) { _ in
            showingAddSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .snagOpenTorrentFile)) { _ in
            openTorrentFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snagRequestDelete)) { note in
            if let id = note.object as? Int, let torrent = store.torrents.first(where: { $0.id == id }) {
                pendingDelete = torrent
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        // The View > Appearance picker lives in the menu bar, which has no view lifecycle,
        // so the window applies the stored choice whenever it changes.
        .onChange(of: appearance) { _, new in new.apply() }
    }

    @ViewBuilder
    private var content: some View {
        if !store.daemonRunning && store.torrents.isEmpty {
            ContentUnavailableView {
                Label("Daemon Not Running", systemImage: "power")
            } description: {
                Text("SnagTorrent downloads in a background daemon.")
            } actions: {
                Button("Start Daemon") { Task { await store.startDaemon() } }
                    .disabled(store.startingDaemon)
            }
        } else if store.torrents.isEmpty {
            ContentUnavailableView {
                Label("No Torrents", systemImage: "arrow.down.circle")
            } description: {
                Text("Add a magnet link or drop a .torrent file here.")
            } actions: {
                Button("Add Torrent…") { showingAddSheet = true }
            }
        } else if visibleTorrents.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else {
            table
        }
    }

    private var table: some View {
        @Bindable var store = store
        return Table(visibleTorrents, selection: $selection, sortOrder: $store.sortOrder) {
            TableColumn("Name", value: \.name) { torrent in
                Text(torrent.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(torrent.name)
            }
            .width(min: 140, ideal: 170)

            TableColumn("Status", value: \.state) { torrent in
                Label(torrent.status.label, systemImage: torrent.status.symbol)
                    .foregroundStyle(statusColor(torrent.status))
                    .help(torrent.error ?? torrent.status.label)
            }
            .width(min: 108, ideal: 112, max: 150)

            TableColumn("Progress", value: \.fraction) { torrent in
                HStack(spacing: 8) {
                    ProgressBar(fraction: torrent.fraction,
                                color: torrent.isComplete ? .green : (torrent.isPaused ? .secondary : .accentColor))
                    Text(Format.percent(torrent.fraction))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .width(min: 130, ideal: 150)

            TableColumn("Size", value: \.totalBytes) { torrent in
                Text(Format.size(torrent.totalBytes)).monospacedDigit()
            }
            .width(min: 66, ideal: 72, max: 110)
            .alignment(.trailing)

            TableColumn("Down", value: \.downloadSpeed) { torrent in
                Text(Format.rate(torrent.downloadSpeed)).monospacedDigit()
            }
            .width(min: 72, ideal: 78, max: 110)
            .alignment(.trailing)

            TableColumn("Up", value: \.uploadSpeed) { torrent in
                Text(Format.rate(torrent.uploadSpeed)).monospacedDigit()
            }
            .width(min: 72, ideal: 78, max: 110)
            .alignment(.trailing)

            TableColumn("Seeds", value: \.seeders) { torrent in
                Text(torrent.status == .downloading || torrent.status == .seeding ? "\(torrent.seeders)" : "—")
                    .monospacedDigit()
                    .help("Connected peers that have the whole torrent")
            }
            .width(min: 52, ideal: 56, max: 90)
            .alignment(.trailing)

            TableColumn("Leechers", value: \.leechers) { torrent in
                Text(torrent.status == .downloading || torrent.status == .seeding ? "\(torrent.leechers)" : "—")
                    .monospacedDigit()
                    .help("Connected peers that are still downloading")
            }
            .width(min: 64, ideal: 70, max: 100)
            .alignment(.trailing)

            TableColumn("ETA", value: \.etaSortKey) { torrent in
                Text(Format.eta(torrent.etaSeconds)).monospacedDigit()
            }
            .width(min: 60, ideal: 66, max: 110)
            .alignment(.trailing)

            TableColumn("") { torrent in
                RowActions(torrent: torrent, requestDelete: { pendingDelete = $0 })
            }
            .width(124)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: TorrentSummary.ID.self) { ids in
            if let torrent = store.torrents.first(where: { ids.contains($0.id) }) {
                rowMenu(torrent)
            }
        } primaryAction: { ids in
            if let torrent = store.torrents.first(where: { ids.contains($0.id) }) {
                store.play(torrent)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ torrent: TorrentSummary) -> some View {
        Button("Play") { store.play(torrent) }
        Button(torrent.isPaused ? "Resume" : "Pause") { store.togglePause(torrent) }
        Button("Reveal in Finder") { store.revealInFinder(torrent) }
        Divider()
        Button("Remove (Keep Files)") { store.remove(torrent, deleteFiles: false) }
        Button("Delete Torrent and Files…", role: .destructive) { pendingDelete = torrent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var store = store
        ToolbarItem(placement: .navigation) {
            Picker("Filter", selection: $store.filter) {
                ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Show only torrents in this state")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAddSheet = true
            } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .help("Add a magnet link, info hash, torrent URL, or .torrent file (⌘N)")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if store.daemonRunning {
                    Button("Stop Daemon") { Task { await store.stopDaemon() } }
                } else {
                    Button("Start Daemon") { Task { await store.startDaemon() } }
                        .disabled(store.startingDaemon)
                }
                Button("Reveal Downloads Folder") { revealDownloads() }
                Button("Show Daemon Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.client.logURL])
                }
            } label: {
                Label("Daemon", systemImage: "power")
            }
            .help(store.daemonRunning ? "Daemon running" : "Daemon stopped")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(store.daemonRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(store.daemonRunning ? "Daemon running" : "Daemon stopped")
            if store.pendingAdds > 0 {
                ProgressView().controlSize(.mini)
                Text(store.pendingAdds == 1 ? "Adding torrent…" : "Adding \(store.pendingAdds) torrents…")
            }
            Spacer()
            Text("\(visibleTorrents.count) of \(store.torrents.count)")
                .monospacedDigit()
            Label(Format.rate(store.totalDownloadSpeed), systemImage: "arrow.down")
                .monospacedDigit()
            Label(Format.rate(store.totalUploadSpeed), systemImage: "arrow.up")
                .monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func statusColor(_ status: TorrentStatus) -> Color {
        switch status {
        case .downloading: .accentColor
        case .seeding: .green
        case .paused: .secondary
        case .initializing: .secondary
        case .error: .red
        case .unknown: .secondary
        }
    }

    private func revealDownloads() {
        let folder = store.torrents.first?.folderURL.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/SnagTorrent")
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func openTorrentFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose .torrent files to add"
        if panel.runModal() == .OK {
            for url in panel.urls { store.add(fileURL: url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in TorrentStore.shared.add(fileURL: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in TorrentStore.shared.add(url.absoluteString) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in TorrentStore.shared.add(text) }
                }
            }
        }
        return handled
    }
}

/// A thin capsule progress bar; drawn with plain shapes so every row renders the same.
struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 6)
    }
}

/// Icon buttons at the trailing end of each row.
struct RowActions: View {
    @Environment(TorrentStore.self) private var store
    let torrent: TorrentSummary
    let requestDelete: (TorrentSummary) -> Void

    var body: some View {
        HStack(spacing: 0) {
            action("Play", "play.rectangle", help: playHelp) { store.play(torrent) }
            action(torrent.isPaused ? "Resume" : "Pause",
                   torrent.isPaused ? "play.circle" : "pause.circle",
                   help: torrent.isPaused ? "Resume" : "Pause") { store.togglePause(torrent) }
            action("Reveal in Finder", "folder", help: "Reveal in Finder") { store.revealInFinder(torrent) }
            action("Remove", "xmark.circle", help: "Remove torrent, keep files") {
                store.remove(torrent, deleteFiles: false)
            }
            action("Delete", "trash", help: "Delete torrent and its files…") { requestDelete(torrent) }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
        .imageScale(.medium)
    }

    private var playHelp: String {
        if let video = torrent.mainVideo {
            return "Play \((video.path as NSString).lastPathComponent)"
        }
        return "No video file; reveals the folder"
    }

    private func action(_ title: String, _ symbol: String, help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .help(help)
    }
}
