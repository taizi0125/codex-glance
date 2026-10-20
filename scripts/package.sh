#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
bash scripts/build.sh "${1:-universal}"
'dist/Codex Glance.app/Contents/MacOS/CodexGlance' --self-test
ditto -c -k --sequesterRsrc --keepParent 'dist/Codex Glance.app' dist/Codex-Glance-macOS.zip
(cd dist && shasum -a 256 Codex-Glance-macOS.zip > SHA256SUMS.txt)
echo 'Packaged dist/Codex-Glance-macOS.zip'
