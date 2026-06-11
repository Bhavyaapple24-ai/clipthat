import Foundation
import AppKit

// ClipThat — instant-replay game clipper for macOS.
//
// Launched as the .app (no arguments) -> menu-bar app with global hotkey ⌥⌘C.
// Debug commands (run from terminal):
//   swift run ClipThat list           -> list displays / apps / windows
//   swift run ClipThat test [secs] [fps] [native]  -> smoke capture, measure FPS + audio
//   swift run ClipThat record [secs]  -> record a real .mp4 (game video + game audio)
//   swift run ClipThat autoclip [s] [fps] [native] -> fill buffer, auto-save, reveal in Finder
//   swift run ClipThat replay [secs]  -> instant-replay buffer; press Enter to save last N secs

let args = CommandLine.arguments
let debugCommands: Set<String> = ["list", "test", "record", "autoclip", "replay"]

// No recognized debug command -> run the real menu-bar app.
if args.count <= 1 || !debugCommands.contains(args[1]) {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
    app.run()
    exit(0)
}

let command = args[1]
let engine = CaptureEngine()

do {
    switch command {
    case "list":
        try await engine.listContent()
    case "test":
        // test [secs] [fps] [native] — e.g. `test 5 120 native` for a ProMotion/4K check.
        let secs = args.count > 2 ? (Double(args[2]) ?? 5) : 5
        let fps = args.count > 3 ? (Int(args[3]) ?? 60) : 60
        let native = args.contains("native")
        try await engine.runCaptureTest(seconds: secs, fps: fps, nativeResolution: native)
    case "record":
        let secs = args.count > 2 ? (Double(args[2]) ?? 10) : 10
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/ClipThat/clip-\(stamp).mp4")
        let recorder = Recorder(outputURL: url)
        try await recorder.start(seconds: secs)
    case "autoclip":
        // Zero-interaction test: run buffer, wait, auto-save, reveal in Finder, exit.
        // autoclip [secs] [fps] [native] — e.g. `autoclip 8 120 native`.
        let warmup = args.count > 2 ? (Double(args[2]) ?? 12) : 12
        let fps = args.count > 3 ? (Int(args[3]) ?? 60) : 60
        let native = args.contains("native")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/ClipThat")
        let buffer = ReplayBuffer(bufferSeconds: 30, outputDir: dir,
                                  fps: fps, nativeResolution: native)
        try await buffer.start()
        print("🔴 Buffer running. Filling for \(Int(warmup))s, then auto-saving…")
        for i in stride(from: Int(warmup), to: 0, by: -1) {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let s = buffer.bufferedStatus()
            FileHandle.standardError.write(
                String(format: "   %2ds left — buffer: %d frames / %.1fs, %d audio\n",
                       i, s.frames, s.seconds, s.audio).data(using: .utf8)!)
        }
        let saved = await buffer.saveClip()
        await buffer.stop()
        if let saved {
            // Reveal the new clip in Finder so it's impossible to miss.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-R", saved.path]
            try? p.run(); p.waitUntilExit()
            print("\n✅ Done. Finder should now be showing your clip.")
        } else {
            print("\n❌ No clip was produced — see the messages above for why.")
        }

    case "replay":
        let bufSecs = args.count > 2 ? (Double(args[2]) ?? 30) : 30
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/ClipThat")
        let buffer = ReplayBuffer(bufferSeconds: bufSecs, outputDir: dir)
        try await buffer.start()
        print("""

        🔴 Instant-replay buffer running — keeping the last \(Int(bufSecs))s.
           Saving to: \(dir.path)
           ▸ Press Enter to save a clip of the last \(Int(bufSecs)) seconds
           ▸ Press Ctrl-C to quit
        """)
        // Heartbeat on stderr so it doesn't interfere with reading Enter on stdin.
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let s = buffer.bufferedStatus()
                FileHandle.standardError.write(
                    String(format: "   …buffer: %d frames / %.1fs, %d audio bufs\n",
                           s.frames, s.seconds, s.audio).data(using: .utf8)!)
            }
        }
        // Block on stdin; capture + encode run on their own queues meanwhile.
        while let _ = readLine() {
            await buffer.saveClip()
        }
        heartbeat.cancel()
        await buffer.stop()
    default:
        print("Unknown command '\(command)'. Use: list | test [secs] | record [secs]")
    }
} catch {
    let ns = error as NSError
    print("Error: \(error.localizedDescription)  (domain=\(ns.domain) code=\(ns.code))")
    if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" || ns.localizedDescription.lowercased().contains("declined") {
        print("""

        ➜ This usually means Screen Recording permission is not granted yet.
          Open: System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording
          enable the terminal app you're running this from, then run again.
        """)
    }
    exit(1)
}
