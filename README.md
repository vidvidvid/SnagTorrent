# SnagTorrent

<img src="assets/SnagTorrent.png" alt="SnagTorrent icon" width="160">

A tiny BitTorrent client for macOS with a sparse CLI, a background daemon, and no web UI or remote control port.

SnagTorrent uses the Rust [rqbit](https://github.com/ikatson/rqbit) engine and is an early-stage MVP, not a full replacement for every desktop torrent client.

## Features

- Magnet links, info hashes, HTTP(S) torrent URLs, and local `.torrent` files
- Progress and transfer-speed listing
- Pause, resume, and removal controls
- Fast resume and session persistence across restarts
- Files kept by default when removing a torrent
- User-only local socket and state directories
- No bundled web interface, UPnP port forwarding, or LAN peer discovery

## Install

Install a recent Rust toolchain, then run:

```sh
cargo install --path .
```

This installs the `snag` command. To build without installing:

```sh
cargo build --release
./target/release/snag --help
```

## Usage

Add a torrent; the daemon starts automatically:

```sh
snag add 'magnet:?xt=urn:btih:...'
snag add /path/to/file.torrent
```

Manage downloads:

```sh
snag list
snag pause 0
snag resume 0
snag remove 0
snag stop
```

Download only some files of a torrent (indices from `snag files`):

```sh
snag files 0
snag select 0 1 3
snag add --only 1,3 /path/to/file.torrent
```

Stream a file while it downloads, or change settings:

```sh
snag stream 0 1
snag config --pause-when-done false
```

Remove a torrent **and its downloaded files**:

```sh
snag remove 0 --delete-files
```

Downloads default to `~/Downloads/SnagTorrent`. Set a different directory before starting the daemon:

```sh
snag start --download-dir /path/to/downloads
```

Run `snag --help` or `snag <command> --help` for all options.

## GUI

A native SwiftUI app lives in `macos/SnagTorrent` (macOS 15 or later).

- **Table** of every torrent with status, progress, size, speeds, seeds, leechers, and ETA. Sort by any column, filter by state, search by name. Errors show under the torrent's name.
- **Row actions**: play, pause/resume, reveal in Finder, remove (keep files), delete with files.
- **Play while downloading**: Play opens a finished video directly, or streams one that is still downloading to your default player (VLC, IINA, QuickTime). The daemon fetches pieces in playback order and serves them on `127.0.0.1` only, behind a random per-session token.
- **Pick files first**: magnet links, URLs, and dropped or opened `.torrent` files show a file list before anything downloads.
- **Details** (⌥⌘I or the toolbar button): stats, folder, hash, and every file with its own progress, a checkbox to change what downloads, and a play button for videos. It closes when nothing is selected.
- **Keyboard**: ⌘F search, Space pause/resume, Delete remove (keeps files), Escape clears the selection. Select several rows to pause or remove them together.
- **When a download finishes**: it is paused instead of seeding (on by default; turn off in Settings), a notification appears, and the Dock badge counts active downloads.
- **Settings** (⌘,): download folder (changing it restarts the daemon), finish behaviour, and whether quitting the app also stops the daemon.
- View > Appearance forces light or dark; File > Set as Default makes it the handler for magnet links and `.torrent` files.

Build and install it (needs Xcode and a Rust toolchain; the app bundles the `snag` binary so the daemon starts on demand):

```sh
macos/SnagTorrent/build.sh --install
```

This builds `snag` in release mode, builds the Swift package, assembles `macos/SnagTorrent/build/SnagTorrent.app`, and copies it to `/Applications`. Omit `--install` to only build. The app talks to the same daemon and state directory as the CLI, so `snag list` and the app always agree.

Run the tests:

```sh
cargo test
(cd macos/SnagTorrent && swift test)
```

## Security and privacy

Control uses a local Unix socket in a user-only directory; there is no HTTP control API. The streaming server listens on `127.0.0.1` only, serves read-only file data, and requires a random token that only local socket clients can learn. State and download directories created by SnagTorrent use owner-only permissions. Torrent names are sanitized before terminal output, and file deletion requires an explicit flag.

BitTorrent is **not anonymous**: trackers and peers can see your IP address. SnagTorrent does not include a VPN or anonymity layer. This project has not received an independent security audit.

## License

Apache-2.0. See [LICENSE](LICENSE).
