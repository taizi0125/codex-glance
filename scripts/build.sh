#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
architecture="${1:-$(uname -m)}"
case "$architecture" in arm64|x86_64|universal) ;; *) echo 'Usage: bash scripts/build.sh [arm64|x86_64|universal]' >&2; exit 2;; esac
mkdir -p .build/module-cache 'dist/Codex Glance.app/Contents/MacOS'
app='dist/Codex Glance.app'
compile() {
  xcrun swiftc Sources/main.swift -O -target "$1-apple-macosx13.0" \
    -module-cache-path "$project_dir/.build/module-cache" \
    -framework AppKit -framework ServiceManagement -o "$2"
}
if [[ "$architecture" == universal ]]; then
  compile arm64 .build/CodexGlance-arm64
  compile x86_64 .build/CodexGlance-x86_64
  xcrun lipo -create .build/CodexGlance-arm64 .build/CodexGlance-x86_64 -output "$app/Contents/MacOS/CodexGlance"
else
  compile "$architecture" "$app/Contents/MacOS/CodexGlance"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $app ($architecture)"
