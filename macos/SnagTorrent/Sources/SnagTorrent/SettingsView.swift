import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(TorrentStore.self) private var store

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(store.downloadDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(store.downloadDirectory.path(percentEncoded: false))
                        Spacer()
                        if store.changingDownloadDirectory {
                            ProgressView().controlSize(.small)
                        }
                        Button("Reveal") { store.revealDownloadDirectory() }
                        Button("Change…", action: chooseFolder)
                            .disabled(store.changingDownloadDirectory)
                    }
                }
                Text("New torrents are saved here. Changing it restarts the daemon; torrents already added keep their current location.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.downloadDirectory
        panel.prompt = "Use This Folder"
        panel.message = "Choose where new torrents are saved"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.changeDownloadDirectory(url) }
        }
    }
}
