import AppKit
import UniformTypeIdentifiers

/// Registers this app as the system default for magnet links and .torrent files.
enum DefaultHandler {
    static let torrentType = UTType("org.bittorrent.torrent") ?? UTType(filenameExtension: "torrent") ?? .data

    @MainActor
    static func makeDefault() async throws {
        let app = Bundle.main.bundleURL
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet")
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: torrentType)
    }

    @MainActor
    static var isDefault: Bool {
        let app = Bundle.main.bundleURL.standardizedFileURL
        guard let magnetURL = URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000") else { return false }
        let magnet = NSWorkspace.shared.urlForApplication(toOpen: magnetURL)?.standardizedFileURL
        let torrent = NSWorkspace.shared.urlForApplication(toOpen: torrentType)?.standardizedFileURL
        return magnet == app && torrent == app
    }
}
