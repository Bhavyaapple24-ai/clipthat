#!/bin/bash
# Build + sign ClipThat.app, zip it for distribution, and print the sha256 the Homebrew
# cask needs. Run this whenever you cut a new release, then upload ClipThat.zip to a
# GitHub release and paste the version + sha256 into packaging/homebrew-tap/Casks/clipthat.rb.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-0.1.0}"

echo "▸ Building + signing ClipThat.app…"
./scripts/bundle.sh >/dev/null

echo "▸ Zipping (ditto keeps the bundle + signature intact)…"
rm -f ClipThat.zip
ditto -c -k --keepParent ClipThat.app ClipThat.zip

SHA=$(shasum -a 256 ClipThat.zip | awk '{print $1}')
SIZE=$(du -h ClipThat.zip | awk '{print $1}')

echo ""
echo "✅ ClipThat.zip  ($SIZE)"
echo "   version : $VERSION"
echo "   sha256  : $SHA"
echo ""
echo "Next:"
echo "  1. gh release create v$VERSION ClipThat.zip -t \"ClipThat $VERSION\" -n \"Release notes…\""
echo "  2. Put version=$VERSION and the sha256 above into packaging/homebrew-tap/Casks/clipthat.rb"
