#!/bin/bash
# One-shot: stable signing identity -> build signed app -> clear stale permission -> launch.
# After running this once and granting permission, future rebuilds won't re-ask.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/setup-signing.sh"
"$ROOT/scripts/bundle.sh"

echo "▸ Clearing any stale Screen Recording permission for the app…"
tccutil reset ScreenCapture com.macmedal.app >/dev/null 2>&1 || true

echo "▸ Quitting any running copy…"
pkill -f "Mac Medal.app" >/dev/null 2>&1 || true
sleep 1

echo "▸ Launching Mac Medal…"
open "$ROOT/Mac Medal.app"

cat <<'EOF'

────────────────────────────────────────────────────────────
LAST STEP (one time only):
  1. A prompt asks to allow Screen & System Audio Recording → Allow / Open Settings.
  2. In Settings ▸ Privacy & Security ▸ Screen & System Audio Recording,
     make sure "Mac Medal" is ON.
  3. Click the ◉ menu-bar icon ▸ Quit, then run:  open "Mac Medal.app"
  4. From now on, rebuilds keep the same signature — no more permission nags.

Then press ⌥⌘C while something is playing to save a 30-second clip.
────────────────────────────────────────────────────────────
EOF
