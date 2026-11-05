import SwiftUI

/// Shown before every download: lists the torrent's files and lets the user pick which to get.
struct FilePickerSheet: View {
    @Environment(TorrentStore.self) private var store
    let flow: TorrentStore.AddFlow
    @State private var selected: Set<Int> = []
    @State private var loadedHash: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch flow {
            case let .fetching(source):
                Text("Fetching Torrent")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(source)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Text("Waiting for metadata from peers. Nothing downloads until you choose files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { store.cancelAdd() }
                        .keyboardShortcut(.cancelAction)
                }
            case let .ready(torrent, _, _):
                Text(torrent.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("\(torrent.files.count) file\(torrent.files.count == 1 ? "" : "s"), \(Format.size(torrent.totalBytes)). Choose what to download.")
                    .foregroundStyle(.secondary)
                fileList(torrent)
                HStack {
                    Button("All") { selected = Set(torrent.files.indices) }
                    Button("None") { selected = [] }
                    Spacer()
                    Text("\(selected.count) selected, \(Format.size(selectedBytes(torrent)))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .controlSize(.small)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { store.cancelAdd() }
                        .keyboardShortcut(.cancelAction)
                    Button("Download") { store.confirmAdd(files: selected) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty)
                }
                .onAppear { syncSelection(torrent) }
                .onChange(of: torrent.infoHash) { syncSelection(torrent) }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func fileList(_ torrent: TorrentPreview) -> some View {
        List {
            ForEach(Array(torrent.files.enumerated()), id: \.offset) { index, file in
                Toggle(isOn: Binding(
                    get: { selected.contains(index) },
                    set: { on in if on { selected.insert(index) } else { selected.remove(index) } }
                )) {
                    HStack {
                        Image(systemName: file.isVideo ? "film" : "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(file.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.path)
                        Spacer()
                        Text(Format.size(file.length))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .listStyle(.bordered)
        .frame(height: min(max(CGFloat(torrent.files.count) * 26 + 12, 60), 320))
    }

    private func selectedBytes(_ torrent: TorrentPreview) -> UInt64 {
        selected.reduce(0) { $0 + (torrent.files.indices.contains($1) ? torrent.files[$1].length : 0) }
    }

    private func syncSelection(_ torrent: TorrentPreview) {
        guard loadedHash != torrent.infoHash else { return }
        loadedHash = torrent.infoHash
        selected = Set(torrent.files.indices)
    }
}
