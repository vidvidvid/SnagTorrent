import SwiftUI

/// Trailing details pane for the selected torrent: stats, error, and per-file progress.
struct InspectorView: View {
    @Environment(TorrentStore.self) private var store
    let torrent: TorrentSummary?

    var body: some View {
        if let torrent {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(torrent)
                    if let error = torrent.error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    stats(torrent)
                    files(torrent)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing", description: Text("Select a torrent to see its details."))
        }
    }

    private func header(_ torrent: TorrentSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(torrent.name)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Label(torrent.status.label, systemImage: torrent.status.symbol)
                    .foregroundStyle(statusColor(torrent.status))
                Spacer()
                Text(Format.percent(torrent.fraction)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressBar(fraction: torrent.fraction,
                        color: torrent.isComplete ? .green : (torrent.isPaused ? .secondary : .accentColor))
        }
    }

    private func stats(_ torrent: TorrentSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Size", "\(Format.size(torrent.progressBytes)) of \(Format.size(torrent.totalBytes))")
            row("Speed", "↓ \(Format.rate(torrent.downloadSpeed))   ↑ \(Format.rate(torrent.uploadSpeed))")
            row("Peers", "\(torrent.seeders) seeds, \(torrent.leechers) leechers")
            row("Uploaded", torrent.uploadedBytes == 0
                ? "—"
                : "\(Format.size(torrent.uploadedBytes)) (ratio \(String(format: "%.2f", torrent.ratio ?? 0)))")
            row("ETA", Format.eta(torrent.etaSeconds))
            GridRow {
                Text("Folder").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Button {
                    store.revealInFinder(torrent)
                } label: {
                    Text(torrent.outputFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help(torrent.outputFolder)
            }
            GridRow {
                Text("Hash").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(torrent.infoHash)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospacedDigit().lineLimit(1)
        }
    }

    private func files(_ torrent: TorrentSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(torrent.files.filter(\.selected).count) of \(torrent.files.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if torrent.files.isEmpty {
                Text("Waiting for metadata…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(torrent.files.enumerated()), id: \.offset) { index, file in
                FileRow(torrent: torrent, index: index, file: file)
            }
        }
    }

    private func statusColor(_ status: TorrentStatus) -> Color {
        switch status {
        case .downloading: .accentColor
        case .seeding: .green
        case .error: .red
        default: .secondary
        }
    }
}

private struct FileRow: View {
    @Environment(TorrentStore.self) private var store
    let torrent: TorrentSummary
    let index: Int
    let file: FileSummary
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { file.selected },
                set: { on in
                    var wanted = Set(torrent.files.indices.filter { torrent.files[$0].selected })
                    if on { wanted.insert(index) } else { wanted.remove(index) }
                    store.setFiles(torrent, files: wanted)
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(file.selected ? "Skip this file" : "Download this file")
            VStack(alignment: .leading, spacing: 3) {
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
                    .foregroundStyle(file.selected ? .primary : .secondary)
                HStack(spacing: 8) {
                    ProgressBar(fraction: file.selected ? file.fraction : 0,
                                color: file.isComplete ? .green : .accentColor)
                        .frame(maxWidth: 140)
                    Text("\(Format.size(file.length))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            if file.isVideo {
                RowActionButton(file.isComplete ? "Play" : "Stream", symbol: "play.rectangle",
                                help: file.isComplete ? "Play" : "Stream while downloading") {
                    store.open(torrent, fileIndex: index)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
