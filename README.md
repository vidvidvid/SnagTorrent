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

Remove a torrent **and its downloaded files**:

```sh
snag remove 0 --delete-files
```

Downloads default to `~/Downloads/SnagTorrent`. Set a different directory before starting the daemon:

```sh
snag start --download-dir /path/to/downloads
```

Run `snag --help` or `snag <command> --help` for all options.

## Security and privacy

Control uses a local Unix socket in a user-only directory; there is no HTTP control API. State and download directories created by SnagTorrent use owner-only permissions. Torrent names are sanitized before terminal output, and file deletion requires an explicit flag.

BitTorrent is **not anonymous**: trackers and peers can see your IP address. SnagTorrent does not include a VPN or anonymity layer. This project has not received an independent security audit.

## License

Apache-2.0. See [LICENSE](LICENSE).
