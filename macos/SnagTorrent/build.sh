#!/bin/sh
# Builds SnagTorrent.app (SwiftUI front end + bundled snag daemon binary).
#   ./build.sh            -> build/SnagTorrent.app
#   ./build.sh --install  -> also copies it to /Applications
set -eu
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
APP="build/SnagTorrent.app"

(cd "$REPO" && cargo build --release)
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SnagTorrent "$APP/Contents/MacOS/SnagTorrent"
cp "$REPO/target/release/snag" "$APP/Contents/MacOS/snag"
cp "$REPO/assets/SnagTorrent.icns" "$APP/Contents/Resources/SnagTorrent.icns"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/SnagTorrent.app
    cp -R "$APP" /Applications/SnagTorrent.app
    echo "Installed /Applications/SnagTorrent.app"
fi
