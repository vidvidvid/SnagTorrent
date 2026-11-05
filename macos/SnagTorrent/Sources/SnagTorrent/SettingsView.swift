import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(TorrentStore.self) private var store
    @AppStorage(TorrentStore.notifyWhenDoneKey) private var notifyWhenDone = true
    @AppStorage(TorrentStore.stopDaemonOnQuitKey) private var stopDaemonOnQuit = false

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
            Section("When a download finishes") {
                Toggle("Pause instead of seeding", isOn: Binding(
                    get: { store.pauseWhenDone },
                    set: { on in Task { await store.setPauseWhenDone(on) } }
                ))
                .disabled(!store.daemonRunning)
                Toggle("Show a notification", isOn: $notifyWhenDone)
            }
            Section("Daemon") {
                Toggle("Stop the daemon when SnagTorrent quits", isOn: $stopDaemonOnQuit)
                Text("Otherwise downloads keep running in the background after the window closes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await store.refreshStatus() }
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
