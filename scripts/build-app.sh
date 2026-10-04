#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
app=".build/YabaiNeighborBar.app"
mkdir -p "$app/Contents/MacOS"
cp Sources/YabaiNeighborBar/Resources/Info.plist "$app/Contents/Info.plist"
cp .build/release/YabaiNeighborBar "$app/Contents/MacOS/YabaiNeighborBar"
# The linker signature does not cover the copied bundle Info.plist; sign the
# assembled app so LaunchServices can launch it reliably.
codesign --force --sign - "$app"
printf 'Built %s\n' "$app"
