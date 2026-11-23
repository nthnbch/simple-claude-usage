#!/bin/bash
# Builds build/ClaudeUsage-<version>.dmg (drag the app onto Applications).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
./build.sh
STAGE="build/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R build/ClaudeUsage.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="build/ClaudeUsage-$VERSION.dmg"; rm -f "$OUT"
hdiutil create -volname "Claude Usage" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "Built $OUT"
