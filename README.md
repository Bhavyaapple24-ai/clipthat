# Mac Medal

An instant-replay game clipper for macOS — like Medal / RetroClip / ShadowPlay, but free and
Mac-native. Always-on rolling buffer; hit a hotkey to save the last N seconds with game audio,
Discord, and mic on **separate tracks**.

## Status — working 🎉

A real signed menu-bar `.app` with:
- Always-on instant-replay buffer (adjustable 15s–5min)
- Hardware H.264 video, no FPS hit
- Full-length, synced game audio
- Global hotkeys, persistent settings
- One-press "share to Discord" via a hosted link

Done:
1. ✅ Capture smoke test (FPS + audio)
2. ✅ Hardware H.264 encoder (VideoToolbox) → `.mp4`
3. ✅ Rolling replay buffer (ring of encoded samples)
4. ✅ Menu-bar app + global hotkey
5. ✅ Audio fixed (deep-copy out of SCK's pool) + concurrent A/V mux
6. ✅ Settings: buffer length + quality, persisted to JSON
7. ✅ Share to Discord: upload clip to catbox.moe, copy inline-playable link

Ideas / not done:
- Compress-for-sharing (shrink >200 MB clips), custom hotkeys, launch at login,
  auto-cleanup, mic track, clip browser UI, Developer ID notarization for public distribution.

## Run the app

```sh
./scripts/setup-signing.sh   # once: stable signature so permission sticks across rebuilds
./scripts/bundle.sh          # build & sign "Mac Medal.app"
open "Mac Medal.app"
```

First launch asks for **Screen & System Audio Recording** permission (shown as "Mac Medal").
Grant it, then reopen. Look for the ◉ icon in the menu bar.

### Controls
- **⌥⌘C** — save the last N seconds (the replay buffer)
- **⌥⌘S** — upload the last clip & copy a Discord-playable link to the clipboard
- Menu ▸ **Buffer Length** / **Quality** — adjust, applied live, saved to
  `~/Library/Application Support/MacMedal/settings.json`
- Menu ▸ **Auto-upload after saving** — copy a share link automatically on every clip
- Menu ▸ **Open Clips Folder** — `~/Movies/MacMedal`

## Build & run (Command Line Tools, no Xcode needed)

```sh
swift build
./.build/debug/MacMedal list        # list displays / apps / windows
./.build/debug/MacMedal test 5      # 5-second smoke capture of the main display
```

### One-time permission setup

Screen capture needs macOS **Screen & System Audio Recording** permission, granted to the app
you run the command *from* (your terminal — Terminal.app, iTerm2, Ghostty, etc.).

1. System Settings ▸ Privacy & Security ▸ **Screen & System Audio Recording**
2. Enable your terminal app (add it with **+** if it isn't listed)
3. Fully quit and reopen the terminal, then run the command again

(When we ship the real `.app` later, it gets its own permission entry and you won't need to grant
this to your terminal.)

## Requirements

- macOS 14.2+ (per-app audio). Built/tested on macOS 26.
- Swift 6 toolchain (Command Line Tools is enough).
