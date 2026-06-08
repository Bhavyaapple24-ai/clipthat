# Afterclip

**A free, open-source instant-replay game clipper for macOS** — like Medal / NVIDIA ShadowPlay,
but Mac-native. Afterclip keeps an always-on rolling buffer of your screen in the background;
press a hotkey to save *the last 30 seconds* (the play you already made), with full game audio.
Then one more hotkey uploads it and copies a **link that plays inline in Discord** — no "file too
big, need Nitro."

> Save the play *after* it happened. 🎬

## Features

- 🔴 **Always-on instant-replay buffer** — adjustable 15s / 30s / 1 min / 2 min / 5 min
- 🎮 **Hardware-encoded H.264 video** (VideoToolbox) — no FPS hit while gaming
- 🔊 **Full-length, synced game audio** captured via ScreenCaptureKit
- ⌨️ **Global hotkeys** that work even in fullscreen games
- 🎚️ **Quality presets** (Low → Ultra) — applied live
- 🔗 **Share to Discord** — uploads the clip and copies an inline-playable link
- ⚙️ **Persistent settings**, lightweight menu-bar app (no Dock clutter)

## Controls

| Hotkey | Action |
|---|---|
| **⌥⌘C** | Save the last N seconds (the replay buffer) |
| **⌥⌘S** | Upload the last clip & copy a Discord-playable link |

Everything else lives in the **◉ menu-bar icon**: buffer length, quality, auto-upload toggle,
and *Open Clips Folder*.

## Requirements

- macOS **14.2 or newer** (per-app audio APIs; built & tested on macOS 26)
- **Xcode Command Line Tools** — `xcode-select --install` (no full Xcode needed)

## Build & install (from source)

```sh
git clone https://github.com/YOUR_USERNAME/afterclip.git
cd afterclip

./scripts/setup-signing.sh   # once: creates a stable local signature so the macOS
                             # Screen-Recording permission sticks across rebuilds
./scripts/bundle.sh          # builds & signs "Afterclip.app"
open "Afterclip.app"
```

On first launch, macOS asks for **Screen & System Audio Recording** permission (shown as
"Afterclip"). Grant it in **System Settings ▸ Privacy & Security ▸ Screen & System Audio
Recording**, then quit and reopen the app. Look for the ◉ icon in your menu bar.

> Building from source avoids Gatekeeper warnings — locally built apps aren't quarantined.

### Custom app icon

Drop a square PNG (ideally 1024×1024) at the repo root named `icon.png`, then re-run
`./scripts/bundle.sh`. It's turned into the app icon automatically.

## Where things live

| What | Path |
|---|---|
| Saved clips | `~/Movies/Afterclip` |
| Settings | `~/Library/Application Support/Afterclip/settings.json` |
| Debug log | `~/Movies/Afterclip/afterclip.log` |

## How sharing works

Afterclip uploads your clip to [catbox.moe](https://catbox.moe) (free, no account) and copies the
resulting direct `.mp4` link to your clipboard. Discord embeds that link and plays it inline, which
sidesteps the attachment size limit. Notes:

- **200 MB** per-file cap (most 30s–1 min clips fit; use a shorter buffer / lower quality if not)
- Links are **public** — anyone with the link can watch (same as Medal)

## How it works (architecture)

- **Capture** — `ScreenCaptureKit` delivers screen frames + system audio on separate queues.
- **Encode** — frames go straight into a `VideoToolbox` H.264 session; only the *encoded* samples
  are kept, in an in-memory ring covering the buffer length.
- **Audio** — buffers are deep-copied out of ScreenCaptureKit's pool (otherwise the pool drains
  and audio delivery stops), kept as PCM in a parallel ring.
- **Save** — on hotkey, the ring is muxed into an `.mp4` with `AVAssetWriter` (video passthrough,
  audio → AAC), starting at the newest keyframe at/before the window start.

## License

MIT — see [LICENSE](LICENSE).

---

*Afterclip is an independent project and is not affiliated with Medal, NVIDIA, or Discord.*
