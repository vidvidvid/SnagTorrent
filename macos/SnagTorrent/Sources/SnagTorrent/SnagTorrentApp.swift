import AppKit
import SwiftUI

@main
struct SnagTorrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = TorrentStore.shared
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some Scene {
        Window("SnagTorrent", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1160, minHeight: 360)
                .onAppear {
                    store.start()
                    #if DEBUG
                    DebugDriver.startIfRequested(store: store)
                    #endif
                }
        }
        .defaultSize(width: 1240, height: 560)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Torrent…") {
                    NotificationCenter.default.post(name: .snagShowAddSheet, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open .torrent File…") {
                    NotificationCenter.default.post(name: .snagOpenTorrentFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Set as Default for Magnet Links and .torrent Files") {
                    Task {
                        do {
                            try await DefaultHandler.makeDefault()
                        } catch {
                            store.alert = .init(title: "Could not set SnagTorrent as default", message: error.localizedDescription)
                        }
                    }
                }
            }
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
            }
            CommandMenu("Daemon") {
                Button("Start Daemon") { Task { await store.startDaemon() } }
                    .disabled(store.daemonRunning || store.startingDaemon)
                Button("Stop Daemon") { Task { await store.stopDaemon() } }
                    .disabled(!store.daemonRunning)
                Divider()
                Button("Show Daemon Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.client.logURL])
                }
            }
        }
    }
}

extension Notification.Name {
    static let snagShowAddSheet = Notification.Name("io.github.vidvidvid.SnagTorrent.showAddSheet")
    static let snagOpenTorrentFile = Notification.Name("io.github.vidvidvid.SnagTorrent.openTorrentFile")
    static let snagRequestDelete = Notification.Name("io.github.vidvidvid.SnagTorrent.requestDelete")
}

/// Handles `.torrent` files and magnet links opened from Finder or a browser.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.applyStored()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                if url.isFileURL {
                    TorrentStore.shared.add(fileURL: url)
                } else {
                    TorrentStore.shared.add(url.absoluteString)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
