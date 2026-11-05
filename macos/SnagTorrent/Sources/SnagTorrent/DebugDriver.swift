#if DEBUG
import AppKit
import Foundation

/// Debug-only test harness, compiled out of Release builds. When `SNAG_DEBUG_DIR`
/// is set it writes a composite PNG of the app's windows and a text dump of the
/// visible table to that directory every half second, and executes one command
/// per line from `<dir>/command` (deleting the file afterwards).
@MainActor
enum DebugDriver {
    static func startIfRequested(store: TorrentStore) {
        guard let path = ProcessInfo.processInfo.environment["SNAG_DEBUG_DIR"], !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            while !Task.isCancelled {
                let commandFile = dir.appendingPathComponent("command")
                if let text = try? String(contentsOf: commandFile, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: commandFile)
                    for line in text.split(separator: "\n") {
                        run(String(line), store: store)
                    }
                }
                writeState(to: dir.appendingPathComponent("state.txt"), store: store)
                try? menuTree(NSApp.mainMenu, indent: "").write(to: dir.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
                capture(to: dir.appendingPathComponent("window.png"))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func run(_ line: String, store: TorrentStore) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        let torrent = Int(argument).flatMap { id in store.torrents.first { $0.id == id } }
        switch verb {
        case "filter": store.filter = StatusFilter(rawValue: argument) ?? .all
        case "search": store.searchText = argument
        case "sort":
            let words = argument.split(separator: " ").map(String.init)
            let order: SortOrder = words.last == "desc" ? .reverse : .forward
            switch words.first ?? "" {
            case "name": store.sortOrder = [KeyPathComparator(\.name, order: order)]
            case "state": store.sortOrder = [KeyPathComparator(\.state, order: order)]
            case "progress": store.sortOrder = [KeyPathComparator(\.fraction, order: order)]
            case "size": store.sortOrder = [KeyPathComparator(\.totalBytes, order: order)]
            case "down": store.sortOrder = [KeyPathComparator(\.downloadSpeed, order: order)]
            case "eta": store.sortOrder = [KeyPathComparator(\.etaSortKey, order: order)]
            case "seeds": store.sortOrder = [KeyPathComparator(\.seeders, order: order)]
            case "leechers": store.sortOrder = [KeyPathComparator(\.leechers, order: order)]
            default: store.sortOrder = [KeyPathComparator(\.id, order: order)]
            }
        case "add": store.add(argument)
        case "pick":
            let indices = Set(argument.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            store.confirmAdd(files: indices)
        case "pickcancel": store.cancelAdd()
        case "addsheet": NotificationCenter.default.post(name: .snagShowAddSheet, object: nil)
        case "toggle": if let torrent { store.togglePause(torrent) }
        case "remove": if let torrent { store.remove(torrent, deleteFiles: false) }
        case "delete": if let torrent { store.remove(torrent, deleteFiles: true) }
        case "confirmdelete": if let torrent { NotificationCenter.default.post(name: .snagRequestDelete, object: torrent.id) }
        case "play": if let torrent { store.play(torrent) }
        case "reveal": if let torrent { store.revealInFinder(torrent) }
        case "stop": Task { await store.stopDaemon() }
        case "start": Task { await store.startDaemon() }
        case "key": sendKey(argument)
        case "click": clickButton(titled: argument)
        case "menu": performMenu(path: argument.split(separator: "/").map(String.init))
        case "paste": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(argument, forType: .string)
        default: break
        }
    }

    /// Sends a synthetic key press (escape or return) to the key window.
    private static func sendKey(_ name: String) {
        // The app runs in the background during tests, so there may be no key window:
        // target the frontmost visible window (a sheet or alert when one is up).
        let frontmost = NSApp.windows.filter { $0.isVisible }.min { $0.orderedIndex < $1.orderedIndex }
        guard let window = NSApp.keyWindow ?? frontmost else { return }
        let (characters, keyCode): (String, UInt16) = name == "return" ? ("\r", 36) : ("\u{1B}", 53)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                window.sendEvent(event)
            }
        }
    }

    private static func menuTree(_ menu: NSMenu?, indent: String) -> String {
        guard let menu else { return "" }
        return menu.items.map { item in
            let state = item.state == .on ? " [on]" : ""
            let line = "\(indent)\(item.isSeparatorItem ? "---" : item.title)\(state)\(item.isEnabled ? "" : " (disabled)")"
            return line + (item.submenu.map { "\n" + menuTree($0, indent: indent + "  ") } ?? "")
        }.joined(separator: "\n")
    }

    /// Triggers a main-menu item by path, e.g. `View/Appearance/Dark`.
    private static func performMenu(path: [String]) {
        var menu = NSApp.mainMenu
        for (index, title) in path.enumerated() {
            // Prefer the item whose submenu contains the next path component (there can be
            // two top-level menus with the same title).
            let next = index + 1 < path.count ? path[index + 1] : nil
            let candidates = menu?.items.filter { $0.title == title } ?? []
            guard let item = candidates.first(where: { candidate in
                next.map { n in candidate.submenu?.items.contains { $0.title == n } ?? false } ?? true
            }) ?? candidates.first else { return }
            if index == path.count - 1 {
                menu?.performActionForItem(at: menu!.index(of: item))
            } else {
                menu = item.submenu
            }
        }
    }

    /// Clicks the first AppKit button with this title in any visible window (alerts, dialogs).
    private static func clickButton(titled title: String) {
        func search(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for subview in view.subviews { if let found = search(subview) { return found } }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView?.superview ?? window.contentView, let button = search(root) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func flowDescription(_ flow: TorrentStore.AddFlow?) -> String {
        switch flow {
        case nil: "none"
        case let .fetching(source): "fetching:\(source)"
        case let .ready(preview, _, paused): "ready:\(preview.name):paused=\(paused):files=\(preview.files.map(\.path).joined(separator: ";"))"
        }
    }

    private static func writeState(to url: URL, store: TorrentStore) {
        var lines = [
            "daemon=\(store.daemonRunning ? "running" : "stopped") pending=\(store.pendingAdds)",
            "filter=\(store.filter.rawValue) search=\(store.searchText)",
            "windows=\(NSApp.windows.filter(\.isVisible).map { "\($0.className):\($0.title)" }.joined(separator: ","))",
            "flow=\(flowDescription(store.addFlow))",
        ]
        for torrent in store.visibleTorrents {
            let video = store.playableVideo(torrent)?.path ?? "-"
            lines.append("\(torrent.id)|\(torrent.name)|\(torrent.state)|\(Format.percent(torrent.fraction))|\(Format.size(torrent.totalBytes))|\(Format.rate(torrent.downloadSpeed))|\(Format.rate(torrent.uploadSpeed))|seeds=\(torrent.seeders)|leech=\(torrent.leechers)|\(Format.eta(torrent.etaSeconds))|files=\(torrent.files.count)|selected=\(torrent.files.indices.filter { torrent.files[$0].selected }.map(String.init).joined(separator: ","))|video=\(video)")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Composites every visible window of this process (main window, sheets, alerts)
    /// into one PNG by rendering each window's frame view (title bar, toolbar, content).
    private static func capture(to url: URL) {
        let windows = NSApp.windows
            .filter { $0.isVisible && $0.frame.width > 1 }
            .sorted { $0.orderedIndex < $1.orderedIndex }
        guard !windows.isEmpty else { return }
        let union = windows.map(\.frame).reduce(windows[0].frame) { $0.union($1) }
        let scale = windows[0].backingScaleFactor
        let size = NSSize(width: union.width * scale, height: union.height * scale)
        guard let combined = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: combined) else { return }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.withAlphaComponent(0).set()
        for window in windows.reversed() {
            guard let frameView = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            frameView.cacheDisplay(in: bounds, to: rep)
            let origin = NSPoint(x: window.frame.minX - union.minX, y: window.frame.minY - union.minY)
            rep.draw(in: NSRect(origin: origin, size: window.frame.size), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = combined.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url.appendingPathExtension("tmp"))
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: url.appendingPathExtension("tmp"), to: url)
    }
}
#endif
